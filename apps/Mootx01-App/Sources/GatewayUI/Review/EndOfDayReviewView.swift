import SwiftUI
import MootGateway

// MARK: - EndOfDayReviewView  (FAB5-G2 — "End-of-Day Review")
//
// ROADMAP.md, "Ask what MOOT remembers": "End-of-Day Review — what changed, what
// was decided, and what still needs attention." Sections are the day's recall,
// the facts filed today, and the lexical odd-ones-out (FAB5-G1's
// `EndOfDayReviewBuilder`).
//
// The `changes` section's items are drawers, so they carry the one reversible
// suggestion in the Review Center: Confirm, which marks a memory verified by you
// and can be contested later. Nothing on this screen is destructive.

struct EndOfDayReviewView: View {
    let report: ReviewReport
    let coordinator: ReviewActionCoordinator

    var body: some View {
        ReviewActionableReportView(report: report, coordinator: coordinator)
    }
}
