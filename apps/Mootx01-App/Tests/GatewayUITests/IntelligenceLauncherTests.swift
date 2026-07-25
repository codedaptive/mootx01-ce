import Testing
import Foundation
@testable import GatewayUI
import MootGateway

// MARK: - Intelligence six-worker launcher (FAB5-H2)
//
// The launcher's availability rules and its result text, asserted without
// rendering a view. Both live in value types beside `IntelligenceView` precisely
// so they can be checked here: an availability rule that only exists inside a
// SwiftUI `body` is a rule nothing can verify.

@Suite("Intelligence launcher — six workers with availability states (FAB5-H2)")
struct IntelligenceLauncherTests {

    static let twoBodies = """
        Latency is 40ms.
        ---
        Latency is 400ms.
        """

    @Test("all six workers are offered, in declaration order")
    func sixWorkersOffered() {
        let entries = WorkerLauncherEntry.entries(modelAvailability: .available, editorText: "")
        #expect(entries.count == 6)
        #expect(entries.map(\.kind) == [.summarize, .extractFacts, .classify, .reviewPrep, .compare, .handoff])
        // Every row carries a caption, so no row is ever offered without a state.
        #expect(entries.allSatisfy { !$0.caption.isEmpty })
    }

    @Test("with Apple Intelligence on and an empty editor, the input-free workers are ready")
    func readyWithoutInput() {
        let byKind = Dictionary(
            uniqueKeysWithValues: WorkerLauncherEntry
                .entries(modelAvailability: .available, editorText: "")
                .map { ($0.kind, $0.state) }
        )
        #expect(byKind[.summarize] == .ready)
        #expect(byKind[.extractFacts] == .ready)
        #expect(byKind[.reviewPrep] == .ready)
        // These three cannot run on an empty editor.
        #expect(byKind[.classify] == .needsInput)
        #expect(byKind[.handoff] == .needsInput)
        #expect(byKind[.compare] == .needsInput)
    }

    @Test("editor text satisfies classify and handoff but not compare")
    func textSatisfiesSomeWorkers() {
        let byKind = Dictionary(
            uniqueKeysWithValues: WorkerLauncherEntry
                .entries(modelAvailability: .available, editorText: "Shipped the launcher today.")
                .map { ($0.kind, $0.state) }
        )
        #expect(byKind[.classify] == .ready)
        #expect(byKind[.handoff] == .ready)
        // One body is not a comparison.
        #expect(byKind[.compare] == .needsInput)
    }

    @Test("two separated bodies make compare runnable")
    func twoBodiesSatisfyCompare() {
        let byKind = Dictionary(
            uniqueKeysWithValues: WorkerLauncherEntry
                .entries(modelAvailability: .available, editorText: Self.twoBodies)
                .map { ($0.kind, $0.state) }
        )
        #expect(byKind[.compare] == .ready)
    }

    @Test("with Apple Intelligence off, satisfied workers offer the fallback path")
    func fallbackOnlyWhenModelUnavailable() {
        let entries = WorkerLauncherEntry.entries(
            modelAvailability: .unavailable, editorText: Self.twoBodies)
        let byKind = Dictionary(uniqueKeysWithValues: entries.map { ($0.kind, $0.state) })
        #expect(byKind[.summarize] == .fallbackOnly)
        #expect(byKind[.compare] == .fallbackOnly)
        #expect(byKind[.classify] == .fallbackOnly)
        // Runnable on the deterministic path — the row is not disabled.
        #expect(entries.filter { !$0.state.isRunnable }.isEmpty)
    }

    @Test("a missing input blocks the row even when Apple Intelligence is off")
    func needsInputOutranksFallback() {
        let byKind = Dictionary(
            uniqueKeysWithValues: WorkerLauncherEntry
                .entries(modelAvailability: .unavailable, editorText: "   \n  ")
                .map { ($0.kind, $0.state) }
        )
        // The fallback cannot invent an objective or a second body, so offering
        // the fallback here would offer a run that produces nothing.
        #expect(byKind[.handoff] == .needsInput)
        #expect(byKind[.compare] == .needsInput)
        #expect(byKind[.classify] == .needsInput)
        #expect(WorkerLauncherState.needsInput.isRunnable == false)
    }

    @Test("a blocked row's caption says what is missing, not just that something is")
    func blockedCaptionNamesTheRequirement() {
        let entries = WorkerLauncherEntry.entries(modelAvailability: .available, editorText: "")
        let compare = entries.first { $0.kind == .compare }
        #expect(compare?.caption == WorkerLauncherKind.compare.inputRequirement)
        #expect(compare?.caption != WorkerLauncherState.needsInput.label)
    }
}

// MARK: - Body splitting

@Suite("Intelligence launcher — compare input splitting (FAB5-H2)")
struct CompareBodySplittingTests {

    @Test("one separator with text on both sides yields two labelled bodies")
    func splitsOnSeparator() {
        let bodies = WorkerLauncherEntry.compareBodies(from: "first\n---\nsecond")
        #expect(bodies?.left.text == "first")
        #expect(bodies?.right.text == "second")
        #expect(bodies?.left.label != bodies?.right.label)
        #expect(!(bodies?.left.label.isEmpty ?? true))
    }

    @Test("no separator is not a comparison")
    func noSeparatorIsNil() {
        #expect(WorkerLauncherEntry.compareBodies(from: "just one body") == nil)
    }

    @Test("an empty side is not a comparison")
    func emptySideIsNil() {
        #expect(WorkerLauncherEntry.compareBodies(from: "first\n---\n   ") == nil)
        #expect(WorkerLauncherEntry.compareBodies(from: "---\nsecond") == nil)
    }

    @Test("two separators are refused rather than guessed at")
    func twoSeparatorsRefused() {
        // Three parts could be split several ways; guessing would silently drop
        // material, so the launcher asks for exactly one separator.
        #expect(WorkerLauncherEntry.compareBodies(from: "a\n---\nb\n---\nc") == nil)
    }

    @Test("a separator line with surrounding spaces still separates")
    func separatorTolerantOfSpaces() {
        #expect(WorkerLauncherEntry.compareBodies(from: "a\n  ---  \nb") != nil)
    }
}

// MARK: - Result rendering

@Suite("Intelligence launcher — result text preserves what the workers preserve (FAB5-H2)")
struct WorkerResultTextTests {

    static func disagreement(_ ordinal: Int, _ topic: String) -> Disagreement {
        Disagreement(
            id: "disagreement:\(ordinal)",
            topic: topic,
            leftLabel: "First body",
            rightLabel: "Second body",
            leftPosition: "\(topic)-left",
            rightPosition: "\(topic)-right"
        )
    }

    /// The comparison layer refuses to dissolve a conflict; this asserts the view
    /// layer does not bury one either — both positions of every disagreement
    /// reach the rendered text.
    @Test("rendered comparison shows both positions of every disagreement")
    func comparisonRendersBothPositions() {
        let result = CompareResult(
            leftLabel: "First body",
            rightLabel: "Second body",
            agreements: [ComparedClaim(id: "agreement:0", topic: "index warmth",
                                       statement: "Both report a warm index.",
                                       supportedBy: ["First body", "Second body"])],
            disagreements: [Self.disagreement(0, "latency"), Self.disagreement(1, "cost")],
            synthesisCandidates: [SynthesisCandidate(
                id: "synthesis:0",
                statement: "Use it for read-heavy work.",
                acknowledgedDisagreementIDs: ["disagreement:0"]
            )]
        )
        let text = WorkerResultText.comparison(result)

        for conflict in result.disagreements {
            #expect(text.contains(conflict.topic))
            #expect(text.contains(conflict.leftPosition))
            #expect(text.contains(conflict.rightPosition))
        }
        #expect(text.contains("index warmth"))
        #expect(text.contains("Use it for read-heavy work."))
        // The conflict no candidate acknowledged is named, not omitted.
        #expect(text.contains("cost"))
    }

    @Test("an empty comparison renders its notice rather than nothing")
    func emptyComparisonRendersNotice() {
        let result = CompareResult(
            leftLabel: "a", rightLabel: "b",
            agreements: [], disagreements: [], synthesisCandidates: []
        )
        let text = WorkerResultText.comparison(result)
        #expect(!text.isEmpty)
        #expect(text == result.notice)
    }

    @Test("a rendered brief carries the surfaces the report read")
    func briefRendersSurfaces() {
        let brief = ReviewBrief(
            headline: "Quiet morning",
            narrative: "Two rooms rose and nothing contradicted.",
            citedSurfaces: [.themeWeather, .memorySearch],
            itemCount: 4,
            origin: .model
        )
        let text = WorkerResultText.brief(brief)
        #expect(text.contains("Quiet morning"))
        #expect(text.contains("Two rooms rose and nothing contradicted."))
        #expect(text.contains("moot_lens_theme_weather"))
        #expect(text.contains("moot_memory_search"))
    }

    @Test("a rendered handoff is the assembled draft, citations included")
    func handoffRendersCitations() {
        let draft = HandoffDraft(
            objective: "Plan the rebuild",
            targetModel: "frontier model",
            background: "Rebuild cost is known.",
            ask: "Propose a schedule.",
            references: [HandoffContextItem(subjectID: "AAAAAAAA-0000-0000-0000-000000000001",
                                            source: "moot_memory_search",
                                            excerpt: "rebuild takes 40 minutes")]
        )
        let text = WorkerResultText.handoff(draft)
        #expect(text == draft.body)
        #expect(text.contains("AAAAAAAA-0000-0000-0000-000000000001"))
        #expect(text.contains("Plan the rebuild"))
    }

    @Test("every rendered triple is marked proposed")
    func triplesRenderAsProposed() {
        let result = ExtractFactsResult(triples: [
            ProposedTriple(subject: "Alice", predicate: "leads", object: "the rebuild")
        ])
        let text = WorkerResultText.triples(result)
        #expect(text.contains("Alice"))
        #expect(text.contains("the rebuild"))
        // The PROPOSED mark survives into the text a person reads.
        #expect(text.lowercased().contains("proposed"))
    }

    @Test("no triples renders an explanation, not an empty pane")
    func noTriplesExplains() {
        #expect(!WorkerResultText.triples(ExtractFactsResult(triples: [])).isEmpty)
    }

    @Test("an empty classification renders an explanation")
    func emptyClassificationExplains() {
        let text = WorkerResultText.classification(
            ClassificationSuggestion(suggestedRoom: "", suggestedTags: []))
        #expect(!text.isEmpty)
    }

    @Test("a populated classification shows the room and the tags")
    func classificationShowsRoomAndTags() {
        let text = WorkerResultText.classification(
            ClassificationSuggestion(suggestedRoom: "engineering", suggestedTags: ["launcher", "ai"]))
        #expect(text.contains("engineering"))
        #expect(text.contains("launcher"))
        #expect(text.contains("ai"))
    }
}
