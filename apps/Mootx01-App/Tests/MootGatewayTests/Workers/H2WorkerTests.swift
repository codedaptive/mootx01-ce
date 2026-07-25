import Testing
import Foundation
import AriaMCP
@testable import MootGateway
import MootIntentKit

// MARK: - FAB5-H2 worker tests
//
// Covers the three workers this mission adds. `MockCaller` is declared in
// WorkerTests.swift in this same target and is reused rather than redeclared;
// that file's mutation-verb list is file-private, so this file carries its own.
//
// The disagreement-preservation suite is the load-bearing one: it drives
// CompareResult's initializer directly with hostile input, because that is where
// the preservation mechanisms live and a model-path test could not prove them.

/// Verbs that would write to the estate. No worker may reach one.
private let h2MutationVerbs: Set<String> = [
    "moot_file_memory",
    "moot_file_fact",
    "moot_update_memory",
    "moot_retire_fact",
    "moot_move_memory",
    "moot_withdraw_memory",
]

// MARK: - Fixture report

/// Builds a real `ReviewReport` the way production does — a G1 builder over the
/// live-captured lens fixtures — so ReviewPrep is exercised against report shapes
/// the estate actually produces rather than a hand-written stand-in.
enum ReviewPrepFixtures {

    /// 2026-07-24T12:00:00Z. The morning window opens at the start of yesterday,
    /// so every journal row in the fixtures falls inside it.
    static let morningNow = Date(timeIntervalSince1970: 1_784_894_400)

    static let schedule = ReviewSchedule(calendar: ReviewSchedule.utcCalendar)

    static func report(_ kind: ReviewKind = .morning, now: Date = morningNow) async -> ReviewReport {
        await ReviewBuilderFactory
            .builder(for: kind, configuration: ReviewConfiguration(), schedule: schedule)
            .build(now: now, reader: StubReviewReader(responses: ReviewFixtures.populated))
    }

    static func emptyReport(_ kind: ReviewKind = .morning, now: Date = morningNow) async -> ReviewReport {
        await ReviewBuilderFactory
            .builder(for: kind, configuration: ReviewConfiguration(), schedule: schedule)
            .build(now: now, reader: StubReviewReader(responses: ReviewFixtures.empty))
    }
}

// MARK: - ReviewPrepWorker

@Suite("ReviewPrepWorker — narrates a built ReviewReport (FAB5-H2)")
struct ReviewPrepWorkerTests {

    @Test("fallback narrates a fixture ReviewReport without an estate read")
    func fallbackOverFixtureReport() async {
        let report = await ReviewPrepFixtures.report()
        #expect(report.itemCount > 0, "fixture report must carry items or the test proves nothing")

        let mock = MockCaller()
        let brief = ReviewPrepWorker().fallback(input: ReviewPrepInput(report: report))

        #expect(brief.origin == .deterministic)
        #expect(!brief.headline.isEmpty)
        #expect(!brief.narrative.isEmpty)
        // Counts and surfaces are copied from the report, never narrated.
        #expect(brief.itemCount == report.itemCount)
        #expect(brief.citedSurfaces == report.contributingSurfaces)
        // Narration reads the report; it must not touch the caller.
        #expect(await mock.calledTools.isEmpty)
    }

    @Test("runSafe over a fixture ReviewReport keeps the report's counts and surfaces")
    func runSafeKeepsReportFacts() async {
        let report = await ReviewPrepFixtures.report()
        let mock = MockCaller()
        let brief = await ReviewPrepWorker().runSafe(
            input: ReviewPrepInput(report: report), caller: mock)

        // Holds on both paths: the model may write either headline, but the
        // count and the surface list are the report's, not the model's.
        #expect(brief.itemCount == report.itemCount)
        #expect(brief.citedSurfaces == report.contributingSurfaces)
        #expect(!brief.narrative.isEmpty)
        #expect(await mock.calledTools.isEmpty, "ReviewPrep must not re-read the estate")
    }

    @Test("digest names every section and caps items per section")
    func digestCapsItems() async {
        let report = await ReviewPrepFixtures.report()
        let digest = ReviewPrepWorker.digest(report, maxItemsPerSection: 2)

        for section in report.sections {
            #expect(digest.contains(section.id), "digest omitted section \(section.id)")
            // At most two item rows per section survive the cap.
            let emitted = section.items.prefix(2).count
            for item in section.items.prefix(emitted) {
                #expect(digest.contains(item.title) || digest.contains(item.detail))
            }
            if section.items.count > 2 {
                // Withheld items are stated, never silently dropped.
                #expect(digest.contains("further items in this section: \(section.items.count - 2)"))
            }
        }
    }

    @Test("an empty report still yields a readable brief")
    func emptyReportStillNarrates() async {
        let report = await ReviewPrepFixtures.emptyReport()
        #expect(report.isEmpty)
        let brief = ReviewPrepWorker().fallback(input: ReviewPrepInput(report: report))
        #expect(!brief.narrative.isEmpty)
        #expect(brief.itemCount == 0)
        #expect(brief.citedSurfaces.isEmpty)
    }
}

// MARK: - CompareWorker — disagreement preservation

@Suite("CompareWorker — disagreements are preserved structurally (FAB5-H2)")
struct CompareDisagreementPreservationTests {

    static let left = ResearchBody(label: "model-a", text: "Latency is 40ms. The index is warm.")
    static let right = ResearchBody(label: "model-b", text: "Latency is 400ms. The index is warm.")
    static let input = CompareInput(left: left, right: right)

    /// THE preservation assertion: a suggestion that lists the same topic as both
    /// agreed and disputed cannot produce an agreement. The disagreement wins and
    /// both positions survive intact.
    @Test("a topic listed as both agreed and disputed resolves to the disagreement")
    func contestedTopicNeverReadsAsAgreement() {
        let suggestion = CompareSuggestion(
            agreements: [
                AgreementSuggestion(topic: "Latency", statement: "Both report the same latency."),
                AgreementSuggestion(topic: "index warmth", statement: "Both report a warm index."),
            ],
            disagreements: [
                DisagreementSuggestion(
                    topic: " latency ",
                    firstPosition: "40ms",
                    secondPosition: "400ms"
                )
            ],
            synthesis: []
        )
        let result = CompareWorker.assemble(suggestion, input: Self.input)

        #expect(result.agreements.map(\.topic) == ["index warmth"])
        #expect(result.disagreements.count == 1)
        let conflict = result.disagreements[0]
        #expect(conflict.leftPosition == "40ms")
        #expect(conflict.rightPosition == "400ms")
        #expect(conflict.leftLabel == "model-a")
        #expect(conflict.rightLabel == "model-b")
    }

    @Test("a half-stated conflict keeps both sides on the record")
    func halfStatedConflictSurvives() {
        let result = CompareWorker.assemble(
            CompareSuggestion(
                agreements: [],
                disagreements: [
                    DisagreementSuggestion(topic: "cost", firstPosition: "", secondPosition: "$12/mo")
                ],
                synthesis: []
            ),
            input: Self.input
        )
        #expect(result.disagreements.count == 1)
        #expect(result.disagreements[0].rightPosition == "$12/mo")
        // The silent side is marked, not dropped — the row would otherwise vanish
        // and the comparison would read as agreement by omission.
        #expect(result.disagreements[0].leftPosition == CompareWorker.unstatedPosition)
        #expect(!result.disagreements[0].leftPosition.isEmpty)
    }

    @Test("a synthesis candidate cannot claim to cover a disagreement that does not exist")
    func acknowledgementsAreClampedToRealDisagreements() {
        let result = CompareWorker.assemble(
            CompareSuggestion(
                agreements: [],
                disagreements: [
                    DisagreementSuggestion(topic: "cost", firstPosition: "$5", secondPosition: "$12")
                ],
                synthesis: [
                    SynthesisSuggestion(
                        statement: "Price depends on tier.",
                        openTopics: ["cost", "a topic nobody raised"]
                    )
                ]
            ),
            input: Self.input
        )
        #expect(result.synthesisCandidates.count == 1)
        #expect(result.synthesisCandidates[0].acknowledgedDisagreementIDs == ["disagreement:0"])
        #expect(result.unacknowledgedDisagreements.isEmpty)
    }

    @Test("a synthesis that ignores a live conflict is surfaced, not smoothed over")
    func unacknowledgedConflictIsVisible() {
        let result = CompareWorker.assemble(
            CompareSuggestion(
                agreements: [],
                disagreements: [
                    DisagreementSuggestion(topic: "latency", firstPosition: "40ms", secondPosition: "400ms"),
                    DisagreementSuggestion(topic: "cost", firstPosition: "$5", secondPosition: "$12"),
                ],
                synthesis: [
                    SynthesisSuggestion(statement: "Use it for read-heavy work.", openTopics: ["latency"])
                ]
            ),
            input: Self.input
        )
        #expect(result.disagreements.count == 2)
        #expect(result.unacknowledgedDisagreements.map(\.topic) == ["cost"])
    }

    @Test("every disagreement survives the cap boundary it is inside")
    func disagreementsSurviveUpToTheCap() {
        let many = (0..<4).map {
            DisagreementSuggestion(topic: "topic-\($0)", firstPosition: "a\($0)", secondPosition: "b\($0)")
        }
        let result = CompareWorker.assemble(
            CompareSuggestion(agreements: [], disagreements: many, synthesis: []),
            input: CompareInput(left: Self.left, right: Self.right, maxClaims: 4)
        )
        #expect(result.disagreements.count == 4)
        #expect(result.disagreements.map(\.topic) == ["topic-0", "topic-1", "topic-2", "topic-3"])
    }

    /// The cap is a prompt instruction, not a schema constraint, so a model can
    /// return more conflicts than were asked for. None may be dropped: the cap
    /// applies to the agreement and synthesis lists only.
    @Test("a disagreement past the cap is still carried, not silently cut")
    func disagreementsExceedTheCapAndSurvive() {
        let five = (0..<5).map {
            DisagreementSuggestion(topic: "topic-\($0)", firstPosition: "a\($0)", secondPosition: "b\($0)")
        }
        let result = CompareWorker.assemble(
            CompareSuggestion(agreements: [], disagreements: five, synthesis: []),
            input: CompareInput(left: Self.left, right: Self.right, maxClaims: 2)
        )
        #expect(result.disagreements.count == 5)
        #expect(result.disagreements.map(\.topic) == ["topic-0", "topic-1", "topic-2", "topic-3", "topic-4"])
        // Ids stay dense and unique past the cap, so a synthesis candidate can
        // still acknowledge the ones beyond it.
        #expect(Set(result.disagreements.map(\.id)).count == 5)
        #expect(result.disagreements.last?.id == "disagreement:4")
    }

    @Test("a capped agreement or synthesis list says so in the notice")
    func cappedListsAreDisclosed() {
        let result = CompareWorker.assemble(
            CompareSuggestion(
                agreements: (0..<4).map {
                    AgreementSuggestion(topic: "agreed-\($0)", statement: "s\($0)")
                },
                disagreements: [
                    DisagreementSuggestion(topic: "cost", firstPosition: "$5", secondPosition: "$12")
                ],
                synthesis: []
            ),
            input: CompareInput(left: Self.left, right: Self.right, maxClaims: 2)
        )
        #expect(result.agreements.count == 2)
        #expect(result.disagreements.count == 1)
        // Withheld agreements are disclosed rather than invisible.
        #expect(result.notice != nil)
    }

    /// A zero cap empties the agreement and synthesis lists, so there is nothing
    /// to read: the "nothing was compared" notice is the useful one, and the cap
    /// message must not displace it.
    @Test("a zero cap with nothing left to show keeps the nothing-compared notice")
    func zeroCapKeepsTheNothingComparedNotice() {
        let result = CompareWorker.assemble(
            CompareSuggestion(
                agreements: [AgreementSuggestion(topic: "index warmth", statement: "warm")],
                disagreements: [],
                synthesis: []
            ),
            input: CompareInput(left: Self.left, right: Self.right, maxClaims: 0)
        )
        #expect(result.agreements.isEmpty)
        #expect(result.disagreements.isEmpty)
        #expect(result.notice != nil)
        #expect(result.notice == CompareResult(
            leftLabel: Self.left.label, rightLabel: Self.right.label,
            agreements: [], disagreements: [], synthesisCandidates: []
        ).notice)
    }

    @Test("a zero cap still carries every disagreement")
    func zeroCapStillCarriesDisagreements() {
        let result = CompareWorker.assemble(
            CompareSuggestion(
                agreements: [AgreementSuggestion(topic: "warmth", statement: "warm")],
                disagreements: [
                    DisagreementSuggestion(topic: "cost", firstPosition: "$5", secondPosition: "$12")
                ],
                synthesis: []
            ),
            input: CompareInput(left: Self.left, right: Self.right, maxClaims: 0)
        )
        // The cap zeroes the agreement list; the conflict is untouched, and the
        // withheld agreement is disclosed because there is now something to read.
        #expect(result.agreements.isEmpty)
        #expect(result.disagreements.count == 1)
        #expect(result.notice != nil)
    }

    @Test("an uncapped comparison carries no truncation notice")
    func uncappedComparisonHasNoNotice() {
        let result = CompareWorker.assemble(
            CompareSuggestion(
                agreements: [AgreementSuggestion(topic: "index warmth", statement: "warm")],
                disagreements: [
                    DisagreementSuggestion(topic: "cost", firstPosition: "$5", secondPosition: "$12")
                ],
                synthesis: []
            ),
            input: CompareInput(left: Self.left, right: Self.right, maxClaims: 6)
        )
        #expect(result.notice == nil)
    }

    @Test("caller provenance survives onto the result")
    func referencesSurviveOntoResult() {
        let left = ResearchBody(label: "packet-7F3A", text: "finding", references: ["drawer-1", "drawer-2"])
        let right = ResearchBody(label: "packet-91BC", text: "finding", references: ["drawer-9"])
        let result = CompareWorker.assemble(
            CompareSuggestion(agreements: [], disagreements: [], synthesis: []),
            input: CompareInput(left: left, right: right)
        )
        #expect(result.leftReferences == ["drawer-1", "drawer-2"])
        #expect(result.rightReferences == ["drawer-9"])
        // And on the fallback path, where no comparison happens at all.
        let fallback = CompareWorker().fallback(input: CompareInput(left: left, right: right))
        #expect(fallback.leftReferences == ["drawer-1", "drawer-2"])
        #expect(fallback.rightReferences == ["drawer-9"])
    }

    @Test("an empty comparison always explains itself — silence is never agreement")
    func emptyComparisonCarriesNotice() {
        let result = CompareWorker.assemble(
            CompareSuggestion(agreements: [], disagreements: [], synthesis: []),
            input: Self.input
        )
        #expect(result.agreements.isEmpty)
        #expect(result.disagreements.isEmpty)
        #expect(result.notice != nil)
        #expect(!(result.notice ?? "").isEmpty)
    }

    @Test("fallback asserts no agreement and says why")
    func fallbackAssertsNoAgreement() async {
        let mock = MockCaller()
        let result = CompareWorker().fallback(input: Self.input)
        #expect(result.agreements.isEmpty)
        #expect(result.synthesisCandidates.isEmpty)
        #expect(result.notice != nil)
        #expect(result.leftLabel == "model-a")
        #expect(result.rightLabel == "model-b")
        #expect(await mock.calledTools.isEmpty)
    }

    @Test("runSafe over two bodies never calls a mutation verb")
    func runSafeNoMutation() async {
        let mock = MockCaller()
        _ = await CompareWorker().runSafe(input: Self.input, caller: mock)
        let called = await mock.calledTools
        #expect(called.filter { h2MutationVerbs.contains($0) }.isEmpty)
    }

    /// Work-Packet-shaped input is tolerated, not required: a packet id and body
    /// fit `ResearchBody` with no WorkPacketKit involvement.
    @Test("a packet-shaped body compares without any packet dependency")
    func packetShapedInputTolerated() {
        let packetLike = ResearchBody(
            label: "packet-7F3A",
            text: "Finding: the cache is cold on first read.",
            references: ["7F3A0000-0000-0000-0000-000000000001"]
        )
        let result = CompareWorker.assemble(
            CompareSuggestion(agreements: [], disagreements: [], synthesis: []),
            input: CompareInput(left: packetLike, right: Self.right)
        )
        #expect(result.leftLabel == "packet-7F3A")
        // The packet id the caller passed as provenance is on the result.
        #expect(result.leftReferences == ["7F3A0000-0000-0000-0000-000000000001"])
        #expect(result.notice != nil)
    }
}

// MARK: - HandoffWorker

@Suite("HandoffWorker — drafts carry provenance references (FAB5-H2)")
struct HandoffWorkerTests {

    static let searchFixture = """
        found 2 memory(s)
        AAAAAAAA-0000-0000-0000-000000000001  [engineering]  The index rebuild takes 40 minutes.
        BBBBBBBB-0000-0000-0000-000000000002  [engineering]  Cold reads dominate the first minute.
        recall_provenance: dense_lane:active degraded_stages:none
        """

    @Test("a drafted body cites every reference it carries")
    func bodyCitesEveryReference() {
        let context = [
            HandoffContextItem(subjectID: "AAAAAAAA-0000-0000-0000-000000000001",
                               source: "moot_memory_search", excerpt: "index rebuild takes 40 minutes"),
            HandoffContextItem(subjectID: "BBBBBBBB-0000-0000-0000-000000000002",
                               source: "curated", excerpt: "cold reads dominate the first minute"),
        ]
        let draft = HandoffDraft(
            objective: "Plan the index rebuild",
            targetModel: "frontier model",
            background: "Rebuild cost is known.",
            ask: "Propose a schedule.",
            references: context
        )
        // The initializer assembles the body, so this holds by construction —
        // asserted anyway because it is the guarantee callers rely on.
        for reference in context {
            #expect(draft.body.contains(reference.subjectID))
        }
        #expect(draft.body.contains("Plan the index rebuild"))
        #expect(draft.references.count == 2)
    }

    @Test("recall-sourced context becomes citations with drawer ids")
    func recalledContextBecomesCitations() async {
        let mock = MockCaller(fixture: Self.searchFixture)
        let references = await HandoffWorker.resolveContext(
            HandoffInput(objective: "index rebuild"), caller: mock)

        #expect(references.count == 2)
        #expect(references[0].subjectID == "AAAAAAAA-0000-0000-0000-000000000001")
        #expect(references[0].source == "moot_memory_search")
        #expect(references[0].excerpt == "The index rebuild takes 40 minutes.")
        #expect(await mock.calledTools == ["moot_memory_search"])
    }

    @Test("caller-selected context is used as given and suppresses recall")
    func callerSelectionWins() async {
        let mock = MockCaller(fixture: Self.searchFixture)
        let selected = [HandoffContextItem(subjectID: "CCCCCCCC-0000-0000-0000-000000000003",
                                           source: "curated", excerpt: "hand-picked note")]
        let references = await HandoffWorker.resolveContext(
            HandoffInput(objective: "anything", context: selected), caller: mock)

        #expect(references == selected)
        #expect(await mock.calledTools.isEmpty, "selection must not trigger a recall")
    }

    @Test("a refused recall cites nothing rather than fabricating a source")
    func refusedRecallCitesNothing() async {
        let refusing = RefusingCaller()
        let references = await HandoffWorker.resolveContext(
            HandoffInput(objective: "index rebuild"), caller: refusing)
        #expect(references.isEmpty)

        let draft = HandoffDraft(objective: "index rebuild", targetModel: "frontier model",
                                 background: "b", ask: "a", references: references)
        // The no-context case is stated in the body, not left ambiguous.
        #expect(draft.body.contains("no estate context"))
    }

    @Test("fallback keeps the selected context as citations")
    func fallbackKeepsCitations() async {
        let mock = MockCaller(fixture: Self.searchFixture)
        let selected = [HandoffContextItem(subjectID: "DDDDDDDD-0000-0000-0000-000000000004",
                                           source: "curated", excerpt: "note")]
        let draft = HandoffWorker().fallback(
            input: HandoffInput(objective: "ship the rebuild", context: selected))

        #expect(draft.references == selected)
        #expect(draft.body.contains("DDDDDDDD-0000-0000-0000-000000000004"))
        #expect(draft.body.contains("ship the rebuild"))
        #expect(!draft.background.isEmpty)
        #expect(!draft.ask.isEmpty)
        #expect(await mock.calledTools.isEmpty, "the fallback path calls no tools")
    }

    @Test("an empty query falls back to the objective rather than recalling everything")
    func emptyQueryUsesObjective() {
        let input = HandoffInput(objective: "index rebuild plan")
        #expect(input.query == "index rebuild plan")
    }

    @Test("runSafe never calls a mutation verb")
    func runSafeNoMutation() async {
        let mock = MockCaller(fixture: Self.searchFixture)
        _ = await HandoffWorker().runSafe(
            input: HandoffInput(objective: "index rebuild"), caller: mock)
        let called = await mock.calledTools
        #expect(called.filter { h2MutationVerbs.contains($0) }.isEmpty)
    }
}

// MARK: - Test doubles

/// A caller whose every tool call refuses, for the degraded-surface paths.
actor RefusingCaller: MootToolCalling {
    private(set) var calledTools: [String] = []

    func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult {
        calledTools.append(name)
        return IntentCallResult(text: "refused: estate unavailable", isError: true)
    }
}
