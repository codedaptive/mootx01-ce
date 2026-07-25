import SwiftUI
import MootGateway

// MARK: - WeeklyReviewView  (FAB5-G2 — "Weekly Memory Review")
//
// ROADMAP.md, "Ask what MOOT remembers": "Weekly Memory Review — memories that
// may be stale, duplicated, contradicted, or ready to retire." Sections are
// fading, drift, contradicted, retire-ready, and duplicates (FAB5-G1's
// `WeeklyReviewBuilder`).
//
// This is the housekeeping surface, so it is the one review that offers
// suggestions with mutations behind them: Retire on a retire-ready fact, Accept
// or Reject on a proposed contradiction. The rules for which item gets which
// button live in `ReviewAction.suggestions(forSectionID:item:)`, and the gate
// between a tap and a mutation is `ReviewActionCoordinator` — asking is not
// doing.
//
// Two facets of the roadmap sentence this view cannot deliver, and says so
// rather than faking:
//
//   "duplicated" — no read-only duplicate-detection surface and no merge verb
//   exist at the ARIA surface, so G1 ships `duplicates` as a section whose
//   notice names the missing capability. It renders as that notice. There is no
//   Merge button, because there is nothing behind one.
//
//   "reversible" — retire and reject have no inverse in the substrate, so no
//   Undo ships. Each states its permanence in its confirmation prompt instead.

struct WeeklyReviewView: View {
    let report: ReviewReport
    let coordinator: ReviewActionCoordinator

    var body: some View {
        ReviewActionableReportView(report: report, coordinator: coordinator)
    }
}
