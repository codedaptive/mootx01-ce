import Testing
import Foundation
import AriaMCP
import MootGateway
@testable import GatewayUI

// MARK: - ReviewCenterTests  (FAB5-G2)
//
// Covers the three things the view layer actually decides, none of which needs a
// rendered view:
//
//   1. `ReviewDisplayStrings` resolves every FAB5-G1 title key to display prose,
//      never leaks a raw dotted slug, and leaves estate data alone.
//   2. `ReviewReportView` / `ReviewItemRow`'s pure formatting helpers — item
//      count, coverage line, magnitude, provenance arguments, status label.
//   3. `ReviewCenterModel`'s load state machine: disconnected without a bridge,
//      cached after a build, rebuilt on refresh, deterministic `now`.
//
// Reports under test are built by the REAL FAB5-G1 builders from the same
// live-captured tool responses G1 recorded on 2026-07-24 (see FixtureReader's
// provenance note), so these tests exercise the shapes the app actually renders
// rather than hand-assembled ones that could drift from the builders.

// MARK: - Fixture reader

/// Replays recorded ARIA responses and counts calls.
///
/// PROVENANCE. The response strings below are the same live captures FAB5-G1
/// recorded from a local estate on 2026-07-24 and pinned in
/// `Tests/MootGatewayTests/Review/ReviewFixtures.swift`, re-declared here because
/// a test target cannot import another test target. They are copies, not
/// paraphrases — truncated in row count only, exactly as G1 truncated them. The
/// `moot_fact_search` rows are the one exception and are transcribed from the
/// formatter in `ToolDispatch.runFactSearch`, which is how G1 labels them too.
actor FixtureReader: ReviewSurfaceReading {
    private let responses: [ReviewSurface: String]
    private let structured: [ReviewSurface: JSONValue]
    private(set) var callCount = 0

    /// `structured` mirrors the recall family's structuredContent block —
    /// the rows review items derive from; text-only surfaces omit it.
    init(
        responses: [ReviewSurface: String],
        structured: [ReviewSurface: JSONValue] = [:]
    ) {
        self.responses = responses
        self.structured = structured
    }

    func call(
        _ surface: ReviewSurface, arguments: [String: JSONValue]
    ) async -> ReviewToolResponse {
        callCount += 1
        guard let text = responses[surface] else {
            return ReviewToolResponse(
                text: "no fixture for \(surface.rawValue)", isError: true)
        }
        return ReviewToolResponse(text: text, structured: structured[surface], isError: false)
    }
}

enum ReviewUIFixtures {

    static let themeWeather = """
        theme_weather: 20 result(s)
          - 820E4924-F81A-4EB3-9F74-F2ADCCF73483 momentum=0.017680074613053376
          - 569EE15B-8950-4539-879D-0262DAA5DC3A momentum=0.013475476812148085
          - 2D23EDF6-1DCD-4916-9983-F5C8A1BDF65A momentum=-0.0003194910701785972
        hint: lens results are thin — try scope: active for a broader search
        """

    static let keystones = """
        keystones: 3 result(s)
          - 3D2EE55F-CAE5-4A8A-846E-0BFD9AC413E7 centrality=0.7071064739073133
          - 057E744D-CEA8-4B40-A2E1-62118D79870D centrality=0.0653720734540243
          - 058DAAE5-1275-4E4B-9B48-65B6DAD56886 centrality=0.0653720734540243
        """

    static let contradiction = """
        contradicts_tunnels: 2
          0816C3B2-651D-43F5-82B1-88900DEEC8A0 contradicts 4F0C3009-CB52-47F9-9E96-4EE8DBB87AC4 (tunnel DAAAE428-B717-4053-93F7-77AD5E561438) [proposed (agent-derived, unreviewed) — accept/reject via moot_review_tunnel]
          <hidden> contradicts 4299DF43-9387-4BC1-A413-0885307BA383 (tunnel B42BE134-E317-44D1-9AB2-D6BFD8BDCB4D) [proposed (agent-derived, unreviewed) — accept/reject via moot_review_tunnel]
        conflicting_facts: 1 subject+predicate pair(s)
          [forge_v10] phase1_state
            8F3EB809-10CD-40C0-9989-49EE6FA85A8D  object=[ACCEPTED live by Bob 2026-07-05; merged to forge develop at 1df6a36]  source=mootx01  filed=2026-07-05T09:28:59Z
            843C301F-23A0-4F23-BC1D-A5090842CBD3  object=[ACCEPTED 2026-07-05 single tree develop]  source=599ED465-7C48-4567-8382-0D8E2396081D  filed=2026-07-09T20:53:30Z
        """

    /// Dense-row text (transcribed from DenseRow.render after the PR-03
    /// migration) — feeds only notices. Items derive from
    /// `memorySearchStructured` below, mirroring
    /// `Tests/MootGatewayTests/Review/ReviewFixtures.swift`.
    static let memorySearch = """
        found 2 memory(s)
        DFA470F5-4D6C-48E6-AF8C-56E535F1DD43 · W2-INTERFACE FAB5-I1: WorkPacketKit Schema + Persistence — Interface Summary · fdc:D2 · qid:Q00 · 2026-07-23T18:04:11Z
        591F3E67-878E-4373-A6FC-3406B26E38D8 · W2-INTERFACE FAB5-L1: iPadOS Enablement — defect list and second-pass note. · fdc:D2 · qid:Q00 · 2026-07-23T18:05:02Z
        discrimination: medium — partial separation.
        """

    /// The structured twin of `memorySearch` — the structuredContent block
    /// the recall family carries beside the text; review items derive from
    /// these rows.
    static let memorySearchStructured: JSONValue = .object([
        "results": .array([
            .object([
                "id": .string("DFA470F5-4D6C-48E6-AF8C-56E535F1DD43"),
                "room": .string("fab5-w2"),
                "content": .string("W2-INTERFACE FAB5-I1: WorkPacketKit Schema + Persistence — Interface Summary"),
                "subject": .string("W2-INTERFACE FAB5-I1: WorkPacketKit Schema + Persistence — Interface Summary"),
            ]),
            .object([
                "id": .string("591F3E67-878E-4373-A6FC-3406B26E38D8"),
                "room": .string("fab5-w2"),
                "content": .string("W2-INTERFACE FAB5-L1: iPadOS Enablement — defect list and second-pass note."),
                "subject": .string("W2-INTERFACE FAB5-L1: iPadOS Enablement — defect list and second-pass note."),
            ]),
        ])
    ])

    /// Structured blocks per surface for the populated map (recall family only).
    static let populatedStructured: [ReviewSurface: JSONValue] = [
        .memorySearch: memorySearchStructured
    ]

    /// Journal stamps are inside the morning window used below (`referenceNow`
    /// is 2026-07-25T12:00:00Z; morning's window opens at the start of the 24th).
    static let journal = """
        journal for mcp-agent: 2 entry(s)
        [2026-07-25T09:50:25Z]  FAB5-G1 stream complete. ReviewKit lens aggregation delivered.
        [2026-07-24T21:31:43Z]  SESSION:2026-07-24|inbox.batch:MXC-2026-0052..0056|VERDICT:ACCEPT.all5
        """

    static let cohesion = """
        cohesion_outliers (considered 50): 2 result(s)
          - D99B504F-C344-4A24-900E-227826AE4D0F
          - 102E33DF-2D7D-4349-A507-19DB8D435DE3
        """

    static let drift = """
        drift: before=10 after=50
        jensenShannon: 0.2732
        klDivergence: 0.4471
        """

    /// Transcribed from `ToolDispatch.runFactSearch`'s formatter, not live —
    /// same provenance class G1 flagged for this one surface.
    static let facts = """
        facts: 2
        11111111-1111-4111-8111-111111111111  [ce-release] version_is [1.1.0-beta-04]  filed=2026-07-25T09:00:00Z  source=DFA470F5-4D6C-48E6-AF8C-56E535F1DD43
        22222222-2222-4222-8222-222222222222  [ce-release] cut_by [Bob]  filed=2026-07-01T09:00:00Z  source=<hidden>
        """

    static let populated: [ReviewSurface: String] = [
        .themeWeather: themeWeather,
        .keystones: keystones,
        .contradiction: contradiction,
        .memorySearch: memorySearch,
        .journal: journal,
        .cohesion: cohesion,
        .drift: drift,
        .factSearch: facts,
    ]

    /// Every surface answering with nothing to report — transcribed from the
    /// producing code paths, as G1 did.
    static let empty: [ReviewSurface: String] = [
        .themeWeather: "theme_weather: 0 result(s)",
        .keystones: "keystones: 0 result(s)",
        .contradiction: "contradicts_tunnels: none\nconflicting_facts: none",
        .memorySearch: "found 0 memory(s)",
        .journal: "journal for mcp-agent: 0 entry(s)",
        .cohesion: "cohesion_outliers (considered 0): 0 result(s)",
        .drift: "drift: before=0 after=0\njensenShannon: 0.0\nklDivergence: 0.0",
        .factSearch: "facts: 0",
    ]

    /// Fixed instant every test builds against: 2026-07-25T12:00:00Z, whole
    /// seconds (the G1 wire coders carry no fractional part).
    static let referenceNow = Date(timeIntervalSince1970: 1_784_980_800)

    /// A UTC schedule so window arithmetic does not depend on the machine's
    /// timezone — G1 ships `ReviewSchedule.utcCalendar` for exactly this.
    static var utcSchedule: ReviewSchedule {
        ReviewSchedule(calendar: ReviewSchedule.utcCalendar)
    }

    /// Build one report through the REAL FAB5-G1 builder.
    static func report(
        _ kind: ReviewKind,
        responses: [ReviewSurface: String] = populated
    ) async -> ReviewReport {
        let builder = ReviewBuilderFactory.builder(for: kind, schedule: utcSchedule)
        // The structured twin rides along whenever the populated memorySearch
        // text is in play — custom maps that drop the surface get no rows.
        let structured = responses[.memorySearch] == memorySearch
            ? populatedStructured : [:]
        return await builder.build(
            now: referenceNow,
            reader: FixtureReader(responses: responses, structured: structured))
    }
}

// MARK: - 1. Localization key resolution

@Suite("ReviewDisplayStrings — G1 keys resolve to prose (FAB5-G2)")
struct ReviewDisplayStringsTests {

    /// Every key FAB5-G1 emits today. If G1 adds one and this list is not
    /// updated, the fallback test below still guarantees it renders as words.
    static let allG1Keys = [
        "review.section.momentum", "review.section.keystones",
        "review.section.conflicts", "review.section.journal",
        "review.section.context", "review.section.openWork",
        "review.section.changes", "review.section.decisions",
        "review.section.attention", "review.section.fading",
        "review.section.drift", "review.section.contradicted",
        "review.section.retireReady", "review.section.duplicates",
        "review.item.jensenShannon", "review.item.klDivergence",
    ]

    @Test("no G1 key renders as a raw dotted slug")
    func everyKeyResolves() {
        for key in Self.allG1Keys {
            let display = ReviewDisplayStrings.title(forKey: key)
            #expect(display != key, "\(key) resolved to itself")
            #expect(!display.contains("review."), "\(key) leaked its namespace")
            #expect(!display.isEmpty)
        }
    }

    @Test("resolved titles are distinct — no two sections share a label")
    func titlesAreDistinct() {
        let titles = Self.allG1Keys.map { ReviewDisplayStrings.title(forKey: $0) }
        #expect(Set(titles).count == titles.count)
    }

    @Test("an unknown review key humanizes rather than leaking the slug")
    func unknownKeyFallsBack() {
        // The case that matters: a section FAB5-G1 adds after this build ships.
        #expect(ReviewDisplayStrings.title(forKey: "review.section.newThing")
            == "New thing")
        #expect(ReviewDisplayStrings.title(forKey: "review.item.someMeasure")
            == "Some measure")
    }

    @Test("estate data at a title position is returned verbatim")
    func estateDataPassesThrough() {
        // Most items' titles are substrate identifiers, not keys: a drawer id,
        // a room name, a fact subject, a journal timestamp. Localizing any of
        // them would corrupt it (LOCALIZATION_GUIDE.md).
        let drawerID = "3D2EE55F-CAE5-4A8A-846E-0BFD9AC413E7"
        #expect(ReviewDisplayStrings.title(forKey: drawerID) == drawerID)
        #expect(ReviewDisplayStrings.title(forKey: "[forge_v10] phase1_state")
            == "[forge_v10] phase1_state")
        #expect(ReviewDisplayStrings.title(forKey: "2026-07-25T09:50:25Z")
            == "2026-07-25T09:50:25Z")
    }

    @Test("every review has a name and a summary")
    func kindsHaveDisplayText() {
        for kind in ReviewKind.allCases {
            #expect(!ReviewDisplayStrings.name(for: kind).isEmpty)
            #expect(!ReviewDisplayStrings.summary(for: kind).isEmpty)
        }
        // Names must be distinct or the picker segments are ambiguous.
        let names = ReviewKind.allCases.map(ReviewDisplayStrings.name(for:))
        #expect(Set(names).count == names.count)
    }
}

// MARK: - 2. Row and report formatting

@Suite("ReviewReportView — formatting helpers (FAB5-G2)")
struct ReviewReportFormattingTests {

    @Test("magnitude renders as a bare decimal, never a percentage")
    func magnitudeFormatting() {
        // A real centrality value from G1's live capture. Four fraction digits
        // keep 0.0654 and 0.0177 distinguishable.
        let text = ReviewItemRow.magnitudeText(0.0653720734540243)
        #expect(text != nil)
        #expect(text?.contains("%") == false)
        #expect(text?.contains("0") == true)
        // Nil magnitude means "the surface emitted no score" and must not
        // become a displayed zero.
        #expect(ReviewItemRow.magnitudeText(nil) == nil)
    }

    @Test("negative magnitude keeps its sign — fading rooms depend on it")
    func negativeMagnitudeKeepsSign() {
        let text = ReviewItemRow.magnitudeText(-0.0003194910701785972)
        #expect(text?.first == "-")
    }

    @Test("provenance arguments render key-sorted so the text is stable")
    func argumentsAreSorted() {
        let rendered = ReviewItemRow.argumentsText(
            ["topK": "5", "wing": "Agentic Memory"])
        #expect(rendered == "topK=5  wing=Agentic Memory")
        #expect(ReviewItemRow.argumentsText([:]).isEmpty)
    }

    @Test("status labels are distinct and neither is empty")
    func statusLabels() {
        let recorded = ReviewItemRow.statusLabel(.recorded)
        let proposed = ReviewItemRow.statusLabel(.proposed)
        #expect(!recorded.isEmpty)
        #expect(!proposed.isEmpty)
        #expect(recorded != proposed)
    }

    @Test("status is a distinct GLYPH per state, not colour alone")
    func statusSymbolsAreDistinct() {
        // Pinned to the exact names Kong ruling B specified and that were verified
        // present in the system symbol manifest. A misspelled SF Symbol name is
        // not a compile error — it renders as nothing, which would silently
        // reduce status to a colour difference and break the no-colour-only rule.
        #expect(ReviewItemRow.statusSymbolName(.proposed) == "circle.badge.questionmark")
        #expect(ReviewItemRow.statusSymbolName(.recorded) == "checkmark.circle")
        #expect(ReviewItemRow.statusSymbolName(.proposed)
            != ReviewItemRow.statusSymbolName(.recorded))
    }

    @Test("item count is singular for one and plural otherwise")
    func itemCountText() {
        #expect(ReviewReportView.itemCountText(1).hasSuffix("item"))
        #expect(ReviewReportView.itemCountText(0).hasSuffix("items"))
        #expect(ReviewReportView.itemCountText(12).hasSuffix("items"))
        #expect(ReviewReportView.itemCountText(12).contains("12"))
    }

    @Test("the dashboard coverage line never prints its distantPast window start")
    func dashboardCoverageOmitsUnboundedStart() async {
        let report = await ReviewUIFixtures.report(.dashboard)
        let coverage = ReviewReportView.coverage(of: report)
        // ReviewWindow.unbounded starts at Date.distantPast — year 1. Printing it
        // would read as a bug to the user.
        #expect(!coverage.contains("0001"))
        #expect(!coverage.contains("–"), "dashboard has no span to show")
        #expect(coverage.contains("items"))
    }

    @Test("a windowed review's coverage line shows its span")
    func windowedCoverageShowsSpan() async {
        let report = await ReviewUIFixtures.report(.morning)
        let coverage = ReviewReportView.coverage(of: report)
        #expect(coverage.contains("–"))
        #expect(!coverage.contains("0001"))
    }

    @Test("a multi-day span names both dates, not one date and a bare time")
    func multiDaySpanNamesBothDates() async {
        // The live walk on a real estate produced
        // "Jul 18, 2026 at 12:19 AM – 12:19 AM" for the weekly review when each
        // end was formatted independently: the end had dropped its date, so a
        // seven-day window read as a zero-minute one. Both spanned reviews below
        // cross a day boundary, so both must name two dates.
        for kind in [ReviewKind.weekly, .morning] {
            let report = await ReviewUIFixtures.report(kind)
            let span = ReviewReportView.span(of: report)
            let startDay = report.window.start.formatted(
                Date.FormatStyle().month(.abbreviated).day())
            let endDay = report.generatedAt.formatted(
                Date.FormatStyle().month(.abbreviated).day())
            #expect(startDay != endDay, "\(kind.rawValue) fixture must span days")
            #expect(span.contains(startDay), "\(kind.rawValue): \(span)")
            #expect(span.contains(endDay), "\(kind.rawValue): \(span)")
        }
    }

    @Test("a zero-width window falls back to one instant instead of crashing")
    func zeroWidthWindowIsSafe() {
        // Range requires lower < upper. A review generated exactly at its own
        // window start is reachable, so the fallback path must hold.
        let instant = ReviewUIFixtures.referenceNow
        let report = ReviewReport(
            kind: .endOfDay,
            generatedAt: instant,
            window: ReviewWindow(start: instant, end: instant),
            sections: [])
        let span = ReviewReportView.span(of: report)
        #expect(!span.isEmpty)
        #expect(!span.contains("–"))
        #expect(ReviewReportView.coverage(of: report).contains("0 items"))
    }
}

// MARK: - 3. Rendering the four reports

@Suite("Review views — fixture reports render (FAB5-G2)")
struct ReviewFixtureRenderingTests {

    @Test("all four reports build from fixtures with their G1 section ids", arguments: [
        (ReviewKind.dashboard, ["momentum", "keystones", "conflicts"]),
        (ReviewKind.morning, ["journal", "context", "open-work"]),
        (ReviewKind.endOfDay, ["changes", "decisions", "attention"]),
        (ReviewKind.weekly, ["fading", "drift", "contradicted", "retire-ready", "duplicates"]),
    ])
    func reportsCarryExpectedSections(kind: ReviewKind, ids: [String]) async {
        let report = await ReviewUIFixtures.report(kind)
        #expect(report.kind == kind)
        #expect(report.sections.map(\.id) == ids)
        #expect(report.generatedAt == ReviewUIFixtures.referenceNow)
    }

    @Test("every section resolves to display prose, populated or not", arguments: ReviewKind.allCases)
    func everySectionTitleResolves(kind: ReviewKind) async {
        let report = await ReviewUIFixtures.report(kind)
        for section in report.sections {
            let title = ReviewDisplayStrings.title(forKey: section.title)
            #expect(!title.contains("review."), "\(section.id) leaked its key")
        }
    }

    @Test("every item the views render has a resolvable title and provenance", arguments: ReviewKind.allCases)
    func everyItemIsRenderable(kind: ReviewKind) async {
        let report = await ReviewUIFixtures.report(kind)
        for section in report.sections {
            for item in section.items {
                #expect(!ReviewDisplayStrings.title(forKey: item.title).isEmpty)
                // Provenance is what the "Where this came from" disclosure shows.
                // G1 makes it mandatory; the row assumes that.
                #expect(!item.provenance.responseLine.isEmpty)
                #expect(!item.provenance.surface.rawValue.isEmpty)
            }
        }
    }

    @Test("the section either/or holds — populated sections carry no notice", arguments: ReviewKind.allCases)
    func populatedSectionsHaveNoNotice(kind: ReviewKind) async {
        // The renderer shows items OR the notice, never both. This is G1's
        // contract; the view depends on it, so the view's tests assert it.
        let report = await ReviewUIFixtures.report(kind)
        for section in report.sections {
            if section.items.isEmpty {
                #expect(section.notice != nil, "\(section.id) is empty with no notice")
            } else {
                #expect(section.notice == nil, "\(section.id) has both items and a notice")
            }
        }
    }

    @Test("an empty estate still produces a renderable report", arguments: ReviewKind.allCases)
    func emptyEstateRenders(kind: ReviewKind) async {
        let report = await ReviewUIFixtures.report(
            kind, responses: ReviewUIFixtures.empty)
        #expect(report.isEmpty)
        #expect(report.itemCount == 0)
        // Every section explains itself rather than showing a blank area.
        for section in report.sections {
            #expect(section.notice?.isEmpty == false, "\(section.id) has no notice")
        }
        #expect(ReviewReportView.coverage(of: report).contains("0"))
    }

    @Test("weekly's duplicates section is the named capability gap, not a blank")
    func duplicatesIsAnExplainedGap() async {
        let report = await ReviewUIFixtures.report(.weekly)
        let duplicates = report.sections.first { $0.id == "duplicates" }
        #expect(duplicates != nil)
        #expect(duplicates?.items.isEmpty == true)
        // The notice is substrate-capability prose shown verbatim — it must
        // actually name why nothing can be reported.
        #expect(duplicates?.notice?.contains("duplicate") == true)
    }

    @Test("proposed contradiction edges keep their status through to the row")
    func proposedStatusSurvives() async {
        let report = await ReviewUIFixtures.report(.morning)
        let openWork = report.sections.first { $0.id == "open-work" }
        #expect(openWork?.items.isEmpty == false)
        // The morning review's open-work section is proposed-only by
        // construction; the row's glyph and VoiceOver label key off this.
        #expect(openWork?.items.allSatisfy { $0.status == .proposed } == true)
    }
}

// MARK: - 4. The load state machine

@Suite("ReviewCenterModel — load, cache, refresh (FAB5-G2)")
@MainActor
struct ReviewCenterModelTests {

    /// A model with no estate attached.
    static func disconnectedModel() -> ReviewCenterModel {
        ReviewCenterModel(
            clock: { ReviewUIFixtures.referenceNow },
            makeReader: { nil })
    }

    /// A model over the fixture reader, sharing one reader so call counts
    /// accumulate across builds.
    static func fixtureModel(
        _ reader: FixtureReader
    ) -> ReviewCenterModel {
        ReviewCenterModel(
            schedule: ReviewUIFixtures.utcSchedule,
            clock: { ReviewUIFixtures.referenceNow },
            makeReader: { reader })
    }

    @Test("every shipped review starts idle")
    func startsIdle() {
        let model = Self.disconnectedModel()
        #expect(!model.kinds.isEmpty)
        for kind in model.kinds {
            #expect(model.state(for: kind) == .idle)
        }
    }

    @Test("no bridge means disconnected, and no report is invented")
    func disconnectedWithoutBridge() async {
        let model = Self.disconnectedModel()
        await model.loadIfNeeded(.dashboard)
        #expect(model.state(for: .dashboard) == .disconnected)
    }

    @Test("a disconnected review retries on the next load, unlike a cached one")
    func disconnectedRetries() async {
        // The bridge attaches asynchronously after launch, so a review that was
        // asked too early must be able to succeed later.
        let reader = FixtureReader(responses: ReviewUIFixtures.populated, structured: ReviewUIFixtures.populatedStructured)
        var attached = false
        let model = ReviewCenterModel(
            schedule: ReviewUIFixtures.utcSchedule,
            clock: { ReviewUIFixtures.referenceNow },
            makeReader: { attached ? reader : nil })
        await model.loadIfNeeded(.dashboard)
        #expect(model.state(for: .dashboard) == .disconnected)
        attached = true
        await model.loadIfNeeded(.dashboard)
        guard case .loaded = model.state(for: .dashboard) else {
            Issue.record("expected a loaded report after the bridge attached")
            return
        }
    }

    @Test("a loaded review is cached — reselecting it makes no further tool calls")
    func loadedReportIsCached() async {
        let reader = FixtureReader(responses: ReviewUIFixtures.populated, structured: ReviewUIFixtures.populatedStructured)
        let model = Self.fixtureModel(reader)
        await model.loadIfNeeded(.dashboard)
        let afterFirst = await reader.callCount
        #expect(afterFirst > 0)
        await model.loadIfNeeded(.dashboard)
        #expect(await reader.callCount == afterFirst)
    }

    @Test("refresh rebuilds, and the rebuilt report is equal for a fixed now")
    func refreshRebuilds() async {
        let reader = FixtureReader(responses: ReviewUIFixtures.populated, structured: ReviewUIFixtures.populatedStructured)
        let model = Self.fixtureModel(reader)
        await model.loadIfNeeded(.dashboard)
        guard case .loaded(let first) = model.state(for: .dashboard) else {
            Issue.record("expected a loaded report")
            return
        }
        let afterFirst = await reader.callCount
        await model.reload(.dashboard)
        #expect(await reader.callCount > afterFirst)
        guard case .loaded(let second) = model.state(for: .dashboard) else {
            Issue.record("expected a loaded report after refresh")
            return
        }
        // Same responses + same injected now ⇒ identical report. This is the
        // determinism the injected clock buys.
        #expect(first == second)
    }

    @Test("selecting one review does not build another")
    func buildsOnlyTheSelectedReview() async {
        let reader = FixtureReader(responses: ReviewUIFixtures.populated, structured: ReviewUIFixtures.populatedStructured)
        let model = ReviewCenterModel(
            kinds: ReviewKind.allCases,
            schedule: ReviewUIFixtures.utcSchedule,
            clock: { ReviewUIFixtures.referenceNow },
            makeReader: { reader })
        await model.loadIfNeeded(.dashboard)
        for kind in ReviewKind.allCases where kind != .dashboard {
            #expect(model.state(for: kind) == .idle)
        }
    }

    @Test("the report's generatedAt is the injected whole-second instant")
    func clockIsInjectedAndWholeSecond() async {
        // A sub-second instant must be floored: the G1 wire coders drop the
        // fraction, so a fractional generatedAt would not round-trip.
        let fractional = ReviewUIFixtures.referenceNow.addingTimeInterval(0.75)
        let reader = FixtureReader(responses: ReviewUIFixtures.populated, structured: ReviewUIFixtures.populatedStructured)
        let model = ReviewCenterModel(
            schedule: ReviewUIFixtures.utcSchedule,
            clock: { fractional },
            makeReader: { reader })
        await model.loadIfNeeded(.dashboard)
        guard case .loaded(let report) = model.state(for: .dashboard) else {
            Issue.record("expected a loaded report")
            return
        }
        #expect(report.generatedAt == ReviewUIFixtures.referenceNow)
        let roundTripped = try? ReviewReport.makeDecoder().decode(
            ReviewReport.self,
            from: ReviewReport.makeEncoder().encode(report))
        #expect(roundTripped == report)
    }
}
