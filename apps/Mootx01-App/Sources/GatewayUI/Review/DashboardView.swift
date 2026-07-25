import SwiftUI
import MootGateway

// MARK: - DashboardView  (FAB5-G2 — "MOOT Dashboard")
//
// ROADMAP.md, "Ask what MOOT remembers": "MOOT Dashboard — what your estate
// remembers now." No time window: the dashboard's sections are momentum,
// keystones, and conflicts as they stand (FAB5-G1's `DashboardReviewBuilder`).
//
// Mostly a status surface: momentum rows are keyed by room name and conflict
// rows by tunnel id, and only the latter is settleable. The `keystones` section's
// items are drawers, so those rows carry Confirm — the one reversible suggestion
// in the Review Center.

struct DashboardView: View {
    let report: ReviewReport
    let coordinator: ReviewActionCoordinator

    var body: some View {
        ReviewActionableReportView(report: report, coordinator: coordinator)
    }
}
