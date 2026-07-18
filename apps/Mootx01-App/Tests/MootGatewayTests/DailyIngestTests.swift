import Testing
import Foundation
@testable import MootGateway

// MARK: - DailyIngestSummary tests
//
// The dialog-composition core of DailyIngestIntent. The intent's perform()
// needs the App Intents runtime; the summary text is the testable seam
// (same split as HeavyVerbCore / RecallDrawerIntent.entities(from:)).

@Suite("DailyIngestSummary — dialog text for a tick's outcome")
struct DailyIngestSummaryTests {

    @Test("no summaries: reports that nothing was due, without implying failure")
    func emptyTick() {
        let text = DailyIngestSummary.text(for: [])
        #expect(text.contains("no miners were due"))
        #expect(!text.contains("failed"), "an idle tick is not an error")
    }

    @Test("one source: names the source and the filed/skipped counts")
    func singleSource() {
        let text = DailyIngestSummary.text(for: [
            .init(sourceID: "calendar", result: .init(filed: 3, skipped: 2, failed: 0))
        ])
        #expect(text.contains("calendar"))
        #expect(text.contains("filed 3"))
        #expect(text.contains("skipped 2"))
        #expect(!text.contains("failed"), "failed is only reported when nonzero")
    }

    @Test("multiple sources with a failure: every source named, failure surfaced")
    func multipleSourcesWithFailure() {
        let text = DailyIngestSummary.text(for: [
            .init(sourceID: "calendar", result: .init(filed: 1, skipped: 0, failed: 0)),
            .init(sourceID: "birthdays", result: .init(filed: 0, skipped: 4, failed: 2)),
        ])
        #expect(text.contains("calendar"))
        #expect(text.contains("birthdays"))
        #expect(text.contains("failed 2"))
    }
}
