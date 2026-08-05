import Testing
import Foundation
import AriaMCP
@testable import MootGateway

// MARK: - Review builder tests  (FAB5-G1 Part 2 / Part 3)
//
// Every case drives a builder through StubReviewReader over the live-captured
// fixtures in ReviewFixtures.swift. Three properties are asserted for all four
// builders: determinism under a fixed `now`, provenance on every emitted item,
// and a valid report on an empty estate.

@Suite("Review builders — four reviews over recorded lens surfaces (FAB5-G1)")
struct ReviewBuilderTests {

    /// 2026-07-13T15:33:20Z. Inside the same UTC day as the `filed=` stamp on the
    /// first fact fixture row, so end-of-day window clipping is exercised.
    static let now = Date(timeIntervalSince1970: 1_783_956_800)
    /// 2026-07-24T12:00:00Z — the day after the newest journal fixture entry, so
    /// the morning window (which opens at the start of yesterday) contains all three.
    static let morningNow = Date(timeIntervalSince1970: 1_784_894_400)

    static let schedule = ReviewSchedule(calendar: ReviewSchedule.utcCalendar)
    static let configuration = ReviewConfiguration()

    static func builder(_ kind: ReviewKind) -> any ReviewBuilder {
        ReviewBuilderFactory.builder(for: kind, configuration: configuration, schedule: schedule)
    }

    /// Instant appropriate to each review, so populated fixtures survive window clipping.
    static func instant(for kind: ReviewKind) -> Date {
        kind == .morning ? morningNow : now
    }

    // MARK: Shape

    @Test("the factory returns a builder whose kind matches the request", arguments: ReviewKind.allCases)
    func factoryKindMatches(kind: ReviewKind) {
        #expect(Self.builder(kind).kind == kind)
    }

    @Test("each report carries the injected instant and the scheduled window", arguments: ReviewKind.allCases)
    func reportCarriesWindow(kind: ReviewKind) async {
        let now = Self.instant(for: kind)
        let report = await Self.builder(kind).build(
            now: now, reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        #expect(report.kind == kind)
        #expect(report.generatedAt == now)
        #expect(report.window == Self.schedule.window(for: kind, now: now))
    }

    @Test("section ids are the documented set for each review")
    func sectionIDs() async {
        func ids(_ kind: ReviewKind) async -> [String] {
            await Self.builder(kind).build(
                now: Self.instant(for: kind),
                reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured)
            ).sections.map(\.id)
        }
        #expect(await ids(.dashboard) == ["momentum", "keystones", "conflicts"])
        #expect(await ids(.morning) == ["journal", "context", "open-work"])
        #expect(await ids(.endOfDay) == ["changes", "decisions", "attention"])
        #expect(await ids(.weekly)
                == ["fading", "drift", "contradicted", "retire-ready", "duplicates"])
    }

    @Test("section titles are localization keys, not display prose", arguments: ReviewKind.allCases)
    func titlesAreLocalizationKeys(kind: ReviewKind) async {
        let report = await Self.builder(kind).build(
            now: Self.instant(for: kind),
            reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        for section in report.sections {
            #expect(section.title.hasPrefix("review.section."))
        }
    }

    // MARK: Invariants across all four builders

    @Test("every emitted item carries provenance naming its surface and line",
          arguments: ReviewKind.allCases)
    func provenanceOnEveryItem(kind: ReviewKind) async {
        let report = await Self.builder(kind).build(
            now: Self.instant(for: kind),
            reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        #expect(report.itemCount > 0)
        for section in report.sections {
            for item in section.items {
                #expect(!item.provenance.responseLine.isEmpty)
                #expect(!item.id.isEmpty)
                // The id is namespaced by the tool that produced the item.
                #expect(item.id.hasPrefix(item.provenance.surface.rawValue + ":"))
            }
        }
    }

    @Test("populated sections carry no notice; empty ones always do",
          arguments: ReviewKind.allCases)
    func noticePresenceMatchesEmptiness(kind: ReviewKind) async {
        let report = await Self.builder(kind).build(
            now: Self.instant(for: kind),
            reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        for section in report.sections {
            if section.items.isEmpty {
                #expect(section.notice != nil)
            } else {
                #expect(section.notice == nil)
            }
        }
    }

    @Test("building twice with the same inputs yields byte-identical reports",
          arguments: ReviewKind.allCases)
    func deterministic(kind: ReviewKind) async throws {
        let now = Self.instant(for: kind)
        let first = await Self.builder(kind).build(
            now: now, reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        let second = await Self.builder(kind).build(
            now: now, reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        #expect(first == second)
        let encoder = ReviewReport.makeEncoder()
        let firstBytes = try encoder.encode(first)
        let secondBytes = try encoder.encode(second)
        #expect(firstBytes == secondBytes)
    }

    @Test("builders call read verbs only", arguments: ReviewKind.allCases)
    func readOnly(kind: ReviewKind) async {
        let reader = StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured)
        _ = await Self.builder(kind).build(now: Self.instant(for: kind), reader: reader)
        let called = await reader.calls
        #expect(!called.isEmpty)
        let readVerbs = Set(ReviewSurface.allCases.map(\.rawValue))
        for tool in called {
            #expect(readVerbs.contains(tool))
        }
    }

    // MARK: Empty estate

    @Test("an empty estate produces a valid, empty, fully-explained report",
          arguments: ReviewKind.allCases)
    func emptyEstate(kind: ReviewKind) async throws {
        let report = await Self.builder(kind).build(
            now: Self.instant(for: kind),
            reader: StubReviewReader(responses: ReviewFixtures.empty))
        #expect(report.isEmpty)
        #expect(report.itemCount == 0)
        #expect(!report.sections.isEmpty)
        // Every empty section explains itself in the surface's own words.
        for section in report.sections {
            let notice = try #require(section.notice)
            #expect(!notice.isEmpty)
        }
        // And it still round-trips — an empty review is a renderable review.
        let data = try ReviewReport.makeEncoder().encode(report)
        let decoded = try ReviewReport.makeDecoder().decode(ReviewReport.self, from: data)
        #expect(decoded == report)
    }

    @Test("a refused surface degrades one section and never fails the report",
          arguments: ReviewKind.allCases)
    func refusalDegradesOneSection(kind: ReviewKind) async throws {
        // Refuse one surface this review actually reads — no single surface is
        // common to all four, so the target is chosen per kind.
        let refused: ReviewSurface = switch kind {
        case .dashboard: .themeWeather
        case .morning: .journal
        case .endOfDay: .factSearch
        case .weekly: .drift
        }
        let reader = StubReviewReader(
            responses: ReviewFixtures.populated,
            failing: [refused],
            refusalText: "estate is not open")
        let report = await Self.builder(kind).build(now: Self.instant(for: kind), reader: reader)
        let refusedSections = report.sections.filter {
            $0.notice?.contains("estate is not open") == true
        }
        #expect(!refusedSections.isEmpty)
        for section in refusedSections {
            #expect(section.items.isEmpty)
            // The notice names the tool that refused, then quotes its reason.
            #expect(section.notice == "\(refused.rawValue): estate is not open")
        }
        // Sections fed by healthy surfaces still produced items.
        #expect(report.sections.contains { !$0.items.isEmpty })
    }

    // MARK: Dashboard

    @Test("dashboard ranks momentum, keystones, and conflicts from live captures")
    func dashboardContent() async throws {
        let report = await Self.builder(.dashboard).build(
            now: Self.now, reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        let momentum = try #require(report.sections.first { $0.id == "momentum" })
        // Five rows in the fixture; the trailing `hint:` line is not an item.
        #expect(momentum.items.count == 5)
        #expect(momentum.items[0].subjectID == "820E4924-F81A-4EB3-9F74-F2ADCCF73483")
        #expect(momentum.items[0].magnitude == 0.017680074613053376)
        #expect(momentum.items[0].provenance.surface == .themeWeather)

        let keystones = try #require(report.sections.first { $0.id == "keystones" })
        #expect(keystones.items.count == 5)
        #expect(keystones.items[0].magnitude == 0.7071064739073133)
        // The wing and topK the lens was called with are recorded for lineage.
        #expect(keystones.items[0].provenance.arguments["wing"] == "Agentic Memory")
        #expect(keystones.items[0].provenance.arguments["topK"] == "5")

        let conflicts = try #require(report.sections.first { $0.id == "conflicts" })
        #expect(conflicts.items.count == 3)
        #expect(conflicts.items[0].subjectID == "DAAAE428-B717-4053-93F7-77AD5E561438")
        #expect(conflicts.items[0].status == .proposed)
        #expect(report.contributingSurfaces == [.themeWeather, .contradiction, .keystones])
    }

    // MARK: Morning

    @Test("morning reads the journal, recent context, and only unreviewed findings")
    func morningContent() async throws {
        let report = await Self.builder(.morning).build(
            now: Self.morningNow, reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        let journal = try #require(report.sections.first { $0.id == "journal" })
        #expect(journal.items.count == 3)
        #expect(journal.items[0].occurredAt
                == ISO8601DateFormatter().date(from: "2026-07-23T23:50:25Z"))
        #expect(journal.items[0].detail.hasPrefix("FAB5-FR stream complete"))

        let context = try #require(report.sections.first { $0.id == "context" })
        #expect(context.items.count == 3)
        #expect(context.items[0].subjectID == "DFA470F5-4D6C-48E6-AF8C-56E535F1DD43")
        #expect(context.items[0].title == "fab5-w2")

        let openWork = try #require(report.sections.first { $0.id == "open-work" })
        #expect(openWork.items.allSatisfy { $0.status == .proposed })
        #expect(openWork.items.count == 3)
    }

    @Test("journal entries outside the morning window are clipped, with the reason stated")
    func morningClipsJournalToWindow() async throws {
        // `now` is 2026-07-13; the journal fixture's newest entry is 2026-07-23,
        // so every entry falls outside this window.
        let report = await Self.builder(.morning).build(
            now: Self.now, reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        let journal = try #require(report.sections.first { $0.id == "journal" })
        #expect(journal.items.isEmpty)
        let notice = try #require(journal.notice)
        #expect(notice.contains("journal for mcp-agent: 3 entry(s)"))
        #expect(notice.contains("none filed inside the review window"))
    }

    // MARK: End of day

    @Test("end of day reports changes, today's facts only, and attention")
    func endOfDayContent() async throws {
        let report = await Self.builder(.endOfDay).build(
            now: Self.now, reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        let changes = try #require(report.sections.first { $0.id == "changes" })
        #expect(changes.items.count == 3)

        // Two facts in the fixture: one filed 2026-07-13 (inside the window),
        // one 2026-07-01 (outside). Only the first survives.
        let decisions = try #require(report.sections.first { $0.id == "decisions" })
        #expect(decisions.items.count == 1)
        #expect(decisions.items[0].subjectID == "11111111-1111-4111-8111-111111111111")
        #expect(decisions.items[0].title == "ce-release")
        // Predicate plus object, brackets stripped by the parser.
        #expect(decisions.items[0].detail == "version_is 1.1.0-beta-04")
        #expect(decisions.items[0].occurredAt
                == ISO8601DateFormatter().date(from: "2026-07-13T09:00:00Z"))

        let attention = try #require(report.sections.first { $0.id == "attention" })
        #expect(attention.items.count == 6)
        #expect(attention.items[0].subjectID == "D99B504F-C344-4A24-900E-227826AE4D0F")
        // The cohesion lens emits no score, so magnitude stays nil rather than 0.
        #expect(attention.items[0].magnitude == nil)
    }

    // MARK: Weekly

    @Test("weekly keeps only fading rooms and reports drift over the week")
    func weeklyContent() async throws {
        let reader = StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured)
        let report = await Self.builder(.weekly).build(now: Self.now, reader: reader)

        // Two of the five fixture rows have negative momentum.
        let fading = try #require(report.sections.first { $0.id == "fading" })
        #expect(fading.items.count == 2)
        #expect(fading.items.allSatisfy { ($0.magnitude ?? 0) < 0 })

        let drift = try #require(report.sections.first { $0.id == "drift" })
        #expect(drift.items.count == 2)
        #expect(drift.items[0].title == ReviewLineParsing.jensenShannonTitle)
        #expect(drift.items[0].magnitude == 0.0)
        #expect(drift.items[1].title == ReviewLineParsing.klDivergenceTitle)
        // splitAt is the window start, ISO8601, in the form the lens parses.
        #expect(drift.items[0].provenance.arguments["splitAt"] == "2026-07-06T15:33:20Z")

        let retireReady = try #require(report.sections.first { $0.id == "retire-ready" })
        // Two conflicting groups × two fact rows each.
        #expect(retireReady.items.count == 4)
        #expect(retireReady.items[0].title == "[agent-sdk-gap-analysis-2026-05-02] track1_p1")
        #expect(retireReady.items[0].subjectID == "A3896BD2-5880-4E32-91BF-A7CE3CB63AA5")
        #expect(retireReady.items[2].title == "[forge_v10] phase1_state")
        #expect(retireReady.items[0].occurredAt
                == ISO8601DateFormatter().date(from: "2026-07-04T05:46:42Z"))
    }

    @Test("the duplicate facet ships as a named gap, never as a near-miss mapping")
    func weeklyDuplicateGap() async throws {
        let report = await Self.builder(.weekly).build(
            now: Self.now, reader: StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured))
        let duplicates = try #require(report.sections.first { $0.id == "duplicates" })
        #expect(duplicates.items.isEmpty)
        let notice = try #require(duplicates.notice)
        #expect(notice.contains("No read-only duplicate-detection surface exists yet"))
        // The gap section costs no tool call.
        #expect(notice == WeeklyReviewBuilder.duplicateGapNotice)
    }

    @Test("weekly calls the drift lens with the window start as its split instant")
    func weeklyDriftArgument() async throws {
        let reader = StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured)
        _ = await Self.builder(.weekly).build(now: Self.now, reader: reader)
        let calls = await reader.calls
        let arguments = await reader.callArguments
        let index = try #require(calls.firstIndex(of: "moot_lens_drift"))
        #expect(arguments[index]["splitAt"] == .string("2026-07-06T15:33:20Z"))
    }

    // MARK: Degenerate responses

    @Test("a surface answering with nothing at all yields an explained empty section")
    func blankResponse() async throws {
        // No entry for any surface: every call returns "".
        let report = await Self.builder(.dashboard).build(
            now: Self.now, reader: StubReviewReader(responses: [:]))
        #expect(report.isEmpty)
        for section in report.sections {
            let notice = try #require(section.notice)
            #expect(notice.hasSuffix("returned nothing."))
        }
    }

    @Test("weekly reads the contradiction lens once and parses it for both sections")
    func weeklyReadsContradictionOnce() async {
        // The lens is the most expensive read in the weekly review (tunnel walk
        // plus KG scan); its response feeds both "contradicted" and "retire-ready".
        let reader = StubReviewReader(responses: ReviewFixtures.populated, structured: ReviewFixtures.populatedStructured)
        _ = await Self.builder(.weekly).build(now: Self.now, reader: reader)
        let calls = await reader.calls
        #expect(calls.filter { $0 == "moot_lens_contradiction" }.count == 1)
    }

    @Test("a fact predicate containing 'contradicts' is not misread as a tunnel row")
    func contradictionBlocksAreDisambiguated() async throws {
        // Both blocks of the contradiction response use a two-space indent, so the
        // tunnel parse keys on the "(tunnel …)" annotation and the fact-group parse
        // on a leading bracket. Without that, this group header would surface as a
        // phantom tunnel item.
        var responses = ReviewFixtures.populated
        responses[.contradiction] = """
            contradicts_tunnels: 1
              AAAA1111-1111-4111-8111-111111111111 contradicts BBBB2222-2222-4222-8222-222222222222 (tunnel CCCC3333-3333-4333-8333-333333333333)
            conflicting_facts: 1 subject+predicate pair(s)
              [design-note] contradicts_claim
                DDDD4444-4444-4444-8444-444444444444  object=[the first reading]  source=  filed=2026-07-04T05:46:42Z
            """
        let report = await Self.builder(.weekly).build(
            now: Self.now, reader: StubReviewReader(responses: responses, structured: ReviewFixtures.populatedStructured))
        let contradicted = try #require(report.sections.first { $0.id == "contradicted" })
        #expect(contradicted.items.count == 1)
        #expect(contradicted.items[0].subjectID == "CCCC3333-3333-4333-8333-333333333333")
        let retireReady = try #require(report.sections.first { $0.id == "retire-ready" })
        #expect(retireReady.items.count == 1)
        #expect(retireReady.items[0].title == "[design-note] contradicts_claim")
        #expect(retireReady.items[0].subjectID == "DDDD4444-4444-4444-8444-444444444444")
    }

    @Test("a fact object containing a bracket is not truncated")
    func factObjectWithBracketSurvives() async throws {
        // Real estate rows carry bracketed text inside object values; the object
        // field runs to the LAST bracket before `filed=`, not the first.
        var responses = ReviewFixtures.populated
        responses[.factSearch] = """
            facts: 1
            33333333-3333-4333-8333-333333333333  [aria] grammar_is [a_verb_applied_to_a_noun_[optionally_constrained]]  filed=2026-07-13T09:00:00Z  source=mootx01
            """
        let report = await Self.builder(.endOfDay).build(
            now: Self.now, reader: StubReviewReader(responses: responses, structured: ReviewFixtures.populatedStructured))
        let decisions = try #require(report.sections.first { $0.id == "decisions" })
        #expect(decisions.items.count == 1)
        #expect(decisions.items[0].title == "aria")
        #expect(decisions.items[0].detail
                == "grammar_is a_verb_applied_to_a_noun_[optionally_constrained]")
    }

    @Test("drift on an estate with nothing either side of the split reports no finding")
    func driftWithEmptyDistributions() async throws {
        // The lens still answers 0.0/0.0; a divergence between two empty
        // distributions is not a finding and must not read as "no drift".
        var responses = ReviewFixtures.populated
        responses[.drift] = ReviewFixtures.emptyDrift
        let report = await Self.builder(.weekly).build(
            now: Self.now, reader: StubReviewReader(responses: responses, structured: ReviewFixtures.populatedStructured))
        let drift = try #require(report.sections.first { $0.id == "drift" })
        #expect(drift.items.isEmpty)
        #expect(drift.notice?.contains("drift: before=0 after=0") == true)
    }
}
