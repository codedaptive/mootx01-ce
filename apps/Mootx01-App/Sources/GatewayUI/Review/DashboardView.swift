import SwiftUI
import MootGateway

// MARK: - DashboardView  (FAB5-G2 — "MOOT Dashboard")
//
// ROADMAP.md, "Ask what MOOT remembers": "MOOT Dashboard — what your estate
// remembers now." No time window: the dashboard's sections are momentum,
// keystones, and conflicts as they stand (FAB5-G1's `DashboardReviewBuilder`).
//
// Read-only. Nothing here mutates the estate, so no suggestion actions are
// passed to the shared renderer — the dashboard is a status surface.

struct DashboardView: View {
    let report: ReviewReport

    var body: some View {
        ReviewReportView(report: report)
    }
}
