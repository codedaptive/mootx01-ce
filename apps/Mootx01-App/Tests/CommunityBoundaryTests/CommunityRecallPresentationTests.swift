import AriaMCPWire
import Foundation
import Testing
@testable import MootCommunityGateway
@testable import MootCommunityUI

// MARK: - Community recall presentation (MJ-MOOT-RECALL-LANGUAGE)
//
// Human-language acceptance law applied to the Community Recall pane
// (census com.recall.result R-C6, com.recall.empty R-C7): the pane must not
// render the raw MCP tool-response text as its primary content. The
// `moot_memory_search` reply carries a `structuredContent` block whose rows
// ({id, subject?, firstSentence?, content?, room?, eventTime}) are the one
// truthful source of per-record data, so the pane presents those rows as a
// human result list, keeps the verbatim reply behind an explicitly labeled
// secondary disclosure, and states zero results as an honest empty state.
// When the reply carries no decodable structured block, the presentation
// falls CLOSED to an honestly labeled verbatim reply — never to silently
// dropped rows and never to fabricated structure.

@Suite("Community recall presentation (R-C6/R-C7)")
struct CommunityRecallPresentationTests {

    // MARK: Fixtures

    /// A successful `moot_memory_search` reply whose structuredContent rows
    /// mirror the wire shape the daemon's ResultComposer emits.
    private func call(
        structured: JSONValue?,
        text: String = "found 2 result(s)\n  - raw wire line",
        isError: Bool = false
    ) -> GatewayCall {
        GatewayCall(
            requestJSON: "{}",
            responseJSON: "{}",
            text: text,
            structured: structured,
            isError: isError
        )
    }

    private var twoRows: JSONValue {
        .object(["results": .array([
            .object([
                "id": .string("11111111-2222-3333-4444-555555555555"),
                "subject": .string("Quarterly planning notes"),
                "content": .string("Planning notes body."),
                "room": .string("projects"),
                "eventTime": .string("2026-07-24T10:15:00Z"),
            ]),
            .object([
                "id": .string("66666666-7777-8888-9999-aaaaaaaaaaaa"),
                "firstSentence": .string("A record with no subject."),
                "content": .string("A record with no subject. More body."),
                "eventTime": .string("2026-07-25T08:00:00Z"),
            ]),
        ])])
    }

    // MARK: R-C6 — structured rows become the primary human rendering

    @Test("structured rows decode into human result items with the reply kept verbatim")
    func structuredRowsBecomeResults() throws {
        let outcome = CommunityRecallPresentation.outcome(
            of: call(structured: twoRows))
        guard case .results(let items, let reply) = outcome else {
            Issue.record("expected .results, got \(outcome)")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].subject == "Quarterly planning notes")
        #expect(items[0].room == "projects")
        #expect(items[0].content == "Planning notes body.")
        #expect(items[0].recordedAt == ISO8601DateFormatter()
            .date(from: "2026-07-24T10:15:00Z"))
        // Absent fields stay absent — nothing is fabricated.
        #expect(items[1].subject == nil)
        #expect(items[1].room == nil)
        // The verbatim wire reply survives, demoted to the labeled disclosure.
        #expect(reply == "found 2 result(s)\n  - raw wire line")
    }

    @Test("the primary title is the subject, then the first sentence, never the record id")
    func displayTitlePrefersHumanFields() throws {
        let outcome = CommunityRecallPresentation.outcome(
            of: call(structured: twoRows))
        guard case .results(let items, _) = outcome else {
            Issue.record("expected .results, got \(outcome)")
            return
        }
        #expect(items[0].displayTitle == "Quarterly planning notes")
        #expect(items[1].displayTitle == "A record with no subject.")
        for item in items {
            #expect(!item.displayTitle.contains(item.id),
                    "a record identifier must never be the primary name")
        }
    }

    @Test("a row with neither subject nor first sentence gets an honest absence marker, not its id")
    func displayTitleStatesAbsenceHonestly() {
        let item = CommunityRecallResult(
            id: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
            subject: nil, firstSentence: nil, content: "Body only.",
            room: nil, recordedAt: nil)
        #expect(!item.displayTitle.isEmpty)
        #expect(!item.displayTitle.contains(item.id))
        #expect(item.displayTitle != item.content)
    }

    // MARK: R-C7 — honest empty state

    @Test("an empty results array is presented as the explicit empty state")
    func zeroResultsBecomeEmptyState() throws {
        let outcome = CommunityRecallPresentation.outcome(of: call(
            structured: .object(["results": .array([])]),
            text: "found 0 result(s)"))
        guard case .empty(let reply) = outcome else {
            Issue.record("expected .empty, got \(outcome)")
            return
        }
        #expect(reply == "found 0 result(s)")
    }

    // MARK: Fail-closed fallbacks — honest labeled reply, never guessed rows

    @Test("a reply with no structured block falls closed to the labeled verbatim presentation")
    func missingStructureFallsClosed() {
        let outcome = CommunityRecallPresentation.outcome(of: call(
            structured: nil, text: "prose-only reply"))
        #expect(outcome == .unstructured(reply: "prose-only reply"))
    }

    @Test("a structured block without a results array falls closed")
    func wrongShapeFallsClosed() {
        let outcome = CommunityRecallPresentation.outcome(of: call(
            structured: .object(["rows": .array([])]),
            text: "reply"))
        #expect(outcome == .unstructured(reply: "reply"))
    }

    @Test("a row missing its id fails the whole decode closed — rows are never silently dropped")
    func undecodableRowFallsClosed() {
        let outcome = CommunityRecallPresentation.outcome(of: call(
            structured: .object(["results": .array([
                .object(["subject": .string("No id here")]),
            ])]),
            text: "reply"))
        #expect(outcome == .unstructured(reply: "reply"))
    }

    @Test("an error reply is presented as a failure, with the reply kept verbatim")
    func errorBecomesFailure() {
        let outcome = CommunityRecallPresentation.outcome(of: call(
            structured: nil,
            text: "JSON-RPC error -32000: estate unavailable",
            isError: true))
        #expect(outcome == .failed(
            reply: "JSON-RPC error -32000: estate unavailable"))
    }

    @Test("an unparseable eventTime yields no recorded instant, not a wrong one")
    func malformedInstantStaysAbsent() throws {
        let outcome = CommunityRecallPresentation.outcome(of: call(
            structured: .object(["results": .array([
                .object([
                    "id": .string("11111111-2222-3333-4444-555555555555"),
                    "subject": .string("S"),
                    "eventTime": .string("not-a-date"),
                ]),
            ])])))
        guard case .results(let items, _) = outcome else {
            Issue.record("expected .results, got \(outcome)")
            return
        }
        #expect(items[0].recordedAt == nil)
    }

    // MARK: Model wiring — the pane no longer renders wire text as primary

    /// Sources/MootCommunityUI, located the same way the source guard does.
    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CommunityBoundaryTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/Mootx01-App
            .appendingPathComponent("Sources/MootCommunityUI")
    }

    @Test("the recall pane renders the presentation outcome, not the raw reply string")
    func viewRendersPresentationNotRawText() throws {
        let view = try String(
            contentsOf: sourcesRoot.appendingPathComponent("CommunityContentView.swift"),
            encoding: .utf8)
        #expect(!view.contains("Text(model.recallResult)"),
                "the recall pane must not render the wire reply as primary content (R-C6)")
        #expect(view.contains("recallOutcome"),
                "the recall pane must render the decoded recall outcome")
        #expect(view.contains("recall.reply.title"),
                "the verbatim reply must sit behind an explicitly labeled disclosure")
    }

    @Test("the recall pane wires an explicit human empty state (R-C7)")
    func viewWiresEmptyState() throws {
        let view = try String(
            contentsOf: sourcesRoot.appendingPathComponent("CommunityContentView.swift"),
            encoding: .utf8)
        #expect(view.contains("recall.empty"),
                "zero results must be stated by an explicit empty state, not raw \"found 0\" wire text")
    }

    @Test("the model publishes the decoded outcome instead of a bare reply string")
    func modelPublishesOutcome() throws {
        let model = try String(
            contentsOf: sourcesRoot.appendingPathComponent("CommunityAppModel.swift"),
            encoding: .utf8)
        #expect(!model.contains("recallResult"),
                "the bare reply-string property must be gone, not kept alongside (R-C6)")
        #expect(model.contains("CommunityRecallPresentation.outcome"),
                "recall() must decode through the presentation seam")
    }
}
