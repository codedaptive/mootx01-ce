import SwiftUI
import MootGateway

// MARK: - MorningReviewView  (FAB5-G2 — "Morning Review")
//
// ROADMAP.md, "Ask what MOOT remembers": "Morning Review — the context, open
// work, and reminders that matter today." Sections are the journal since
// yesterday, a recall of recent work, and the contradiction findings still
// awaiting a call (FAB5-G1's `MorningReviewBuilder`).
//
// The `open-work` section lists PROPOSED contradiction edges — findings the
// substrate flagged as needing a human decision rather than settled history.
// Which is why an item's status glyph matters on this screen: `.proposed` rows
// are the ones asking for something.

struct MorningReviewView: View {
    let report: ReviewReport

    var body: some View {
        ReviewReportView(report: report)
    }
}
