import SwiftUI
import MootGateway

// MARK: - ReviewReportView  (FAB5-G2 — the one renderer all four reviews use)
//
// Renders any `ReviewReport`. The four named review views are thin concrete
// wrappers over this (Kong ruling B); Weekly additionally passes an action
// provider so its rows carry suggestion buttons.
//
// Three contract facts from FAB5-G1 shape this file, and each is asserted by a
// test in Tests/GatewayUITests/Review/:
//
//  1. A section is EITHER populated OR carries a notice, never both
//     (ReviewBuilder.swift's section funnel). So the row area is a clean either/or.
//  2. `section.title` and — for the two drift measures — `item.title` are
//     localization KEYS, resolved through ReviewDisplayStrings. Every other
//     `title` and every `detail`/`notice` is estate data, shown verbatim.
//  3. `item.magnitude` is the lens's OWN score (momentum, centrality,
//     divergence). It is not a percentage and not normalized to any range, so it
//     is never suffixed with % and never multiplied.

struct ReviewReportView: View {
    let report: ReviewReport
    /// Suggestion buttons for one item, or `nil` for none. Weekly supplies this;
    /// the read-only reviews leave it nil and render no action affordance at all.
    /// A closure rather than a stored action list so the caller decides
    /// per-item — only some sections of a report are actionable.
    let actions: ((ReviewSection, ReviewItem) -> AnyView?)?

    init(
        report: ReviewReport,
        actions: ((ReviewSection, ReviewItem) -> AnyView?)? = nil
    ) {
        self.report = report
        self.actions = actions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ForEach(report.sections) { section in
                    ReviewSectionView(section: section, actions: actions)
                }
            }
            .padding()
            .frame(maxWidth: UIAdaptivity.readableContentMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ReviewDisplayStrings.summary(for: report.kind))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.coverage(of: report))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "12 items · as of 3:41 PM" and, for the windowed reviews, the span the
    /// report covers.
    ///
    /// The dashboard's window starts at `Date.distantPast`
    /// (`ReviewWindow.unbounded`), so printing its start would read as a
    /// year-1-AD bug. Kind is the documented way to tell the two apart
    /// (`ReviewSchedule.swift`: "callers that care use kind == .dashboard").
    ///
    /// The span goes through the RANGE format style rather than two separate
    /// instants joined by a dash. Formatting each end independently produced
    /// "Jul 18, 2026 at 12:19 AM – 12:19 AM" for the weekly review on a live
    /// estate — the end instant had dropped its date, so a seven-day window read
    /// as a zero-minute one. The range style decides for itself which components
    /// to repeat, and does it per locale.
    nonisolated static func coverage(of report: ReviewReport) -> String {
        let count = itemCountText(report.itemCount)
        guard report.kind != .dashboard else {
            // No window to state: the dashboard is the estate as it stands.
            let generated = report.generatedAt.formatted(
                date: .omitted, time: .shortened)
            return "\(count) · \(String(localized: "as of")) \(generated)"
        }
        return "\(count) · \(span(of: report))"
    }

    /// The window as one phrase. Falls back to the single instant when the window
    /// has no width — `Range` requires a lower bound strictly below its upper, and
    /// a zero-width window is reachable for a review generated exactly at its own
    /// window start.
    nonisolated static func span(of report: ReviewReport) -> String {
        let start = report.window.start
        let end = report.generatedAt
        guard start < end else {
            return end.formatted(date: .abbreviated, time: .shortened)
        }
        return (start..<end).formatted(date: .abbreviated, time: .shortened)
    }

    /// Item count as words. Plural forms would normally come from a
    /// `.stringsdict` (localization rule 3) — this app ships no catalog at all,
    /// so the two cases are written out explicitly rather than assembled by
    /// interpolating a count into one half-sentence. The count itself goes
    /// through `NumberFormatter` (localization rule 2).
    nonisolated static func itemCountText(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: count)) ?? String(count)
        return count == 1
            ? "\(number) \(String(localized: "item"))"
            : "\(number) \(String(localized: "items"))"
    }
}

// MARK: - ReviewActionableReportView

/// A report plus its suggestions: the shared renderer with an action provider
/// wired in, and the confirmation prompt that stands between a tap and a
/// mutation.
///
/// All four reviews render through this. Which items actually get buttons is
/// decided in one place — `ReviewAction.suggestions(forSectionID:item:)` — so
/// there is no per-view action policy to drift. A report whose sections are all
/// unactionable (the dashboard's momentum and conflicts, weekly's drift and
/// duplicates) simply gets no buttons.
struct ReviewActionableReportView: View {
    let report: ReviewReport
    let coordinator: ReviewActionCoordinator

    var body: some View {
        ReviewReportView(report: report) { section, item in
            let actions = ReviewAction.suggestions(
                forSectionID: section.id, item: item)
            // No suggestions, or this row's decision is already made: render no
            // action affordance rather than a disabled one.
            guard !actions.isEmpty, !coordinator.isSettled(item) else { return nil }
            return AnyView(
                ReviewActionRow(
                    actions: actions,
                    outcomeMessage: coordinator.outcomeMessage(for: item),
                    isBusy: coordinator.isPerforming,
                    request: { coordinator.request($0) }))
        }
        // The confirmation prompt. `pending` is set by a tap on a suggestion
        // button and cleared by either arm, so the estate is reached only from
        // the confirm arm — never from the row itself.
        .alert(
            coordinator.pending?.confirmationTitle ?? "",
            isPresented: Binding(
                get: { coordinator.pending != nil },
                set: { presented in
                    // SwiftUI sets this false for an interactive dismissal;
                    // treat that as Cancel, which is the safe reading.
                    if !presented { coordinator.cancelPending() }
                }),
            presenting: coordinator.pending
        ) { action in
            Button(
                action.label,
                role: action.isPermanent ? .destructive : nil
            ) {
                Task { await coordinator.commitPending() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                coordinator.cancelPending()
            }
        } message: { action in
            // What the action does FIRST — and, for a verb the substrate cannot
            // reverse, that it cannot be undone. The estate row id follows as a
            // cross-reference: it is what the user needs to identify the row
            // afterwards, but it is a UUID, so leading with it would bury the
            // sentence that actually informs the decision (Kong polish P-1).
            //
            // `verbatim:` because this is composed at runtime from an
            // already-localized sentence and an estate id. The plain `Text("…")`
            // initializer would take the interpolated result as a LOCALIZATION KEY
            // and try to look the whole thing up.
            Text(verbatim: "\(action.confirmationMessage)\n\n\(action.subjectID)")
        }
    }
}

// MARK: - ReviewActionRow

/// The suggestion buttons for one item, plus the substrate's receipt once one
/// has run.
struct ReviewActionRow: View {
    let actions: [ReviewAction]
    let outcomeMessage: String?
    let isBusy: Bool
    let request: (ReviewAction) -> Void

    /// The 44 pt floor for a touch target (iOS HIG). Applied as a minimum frame
    /// height rather than as padding so it holds at every Dynamic Type size.
    private static let minimumTouchTarget: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Side by side when they fit, stacked when they do not. Two buttons
            // plus their labels overflow a narrow phone at the largest
            // accessibility type sizes, and a clipped action button is an
            // unreachable action (Kong polish P-3).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
            if let outcomeMessage {
                // The substrate's own words about what happened — verbatim.
                Text(outcomeMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The buttons themselves, shared by both `ViewThatFits` candidates so the
    /// two layouts cannot drift apart.
    @ViewBuilder
    private var buttons: some View {
        ForEach(actions, id: \.self) { action in
            Button(action.label) { request(action) }
                .buttonStyle(.bordered)
                .frame(minHeight: Self.minimumTouchTarget)
                .disabled(isBusy)
                .accessibilityLabel(action.accessibilityLabel)
                // Says out loud what the visual destructive role implies, so the
                // permanence is not a colour-only signal.
                .accessibilityHint(
                    action.isPermanent
                        ? String(localized: "Asks you to confirm. Cannot be undone.")
                        : String(localized: "Asks you to confirm."))
        }
    }
}

// MARK: - ReviewSectionView

/// One `ReviewSection`: its resolved title, then either its rows or its notice.
struct ReviewSectionView: View {
    let section: ReviewSection
    let actions: ((ReviewSection, ReviewItem) -> AnyView?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ReviewDisplayStrings.title(forKey: section.title))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if section.items.isEmpty {
                noticeBlock
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(section.items) { item in
                        ReviewItemRow(
                            item: item,
                            action: actions?(section, item))
                        if item.id != section.items.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// The honest-emptiness block. `notice` is the substrate's own words — a
    /// refusal message, a "0 result(s)" reading, or a named capability gap such
    /// as Weekly's duplicate-detection notice — so it is shown verbatim and NOT
    /// localized. The G1 contract guarantees an empty section always carries
    /// one; the `??` arm is unreachable through the builders and exists so a
    /// hand-built section cannot crash the view.
    private var noticeBlock: some View {
        GroupBox {
            Label {
                Text(section.notice ?? String(localized: "Nothing to report."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ReviewItemRow

/// One `ReviewItem`: title, detail, the lens's score, when it was filed, its
/// settled-vs-proposed status, a provenance disclosure, and — on the Weekly
/// review only — its suggestion buttons.
struct ReviewItemRow: View {
    let item: ReviewItem
    let action: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusSymbol
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReviewDisplayStrings.title(forKey: item.title))
                        .font(.body)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if !item.detail.isEmpty, item.detail != item.title {
                        Text(item.detail)              // estate data, verbatim
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .truncationMode(.tail)
                    }
                    if let occurredAt = item.occurredAt {
                        Text(occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if let magnitude = Self.magnitudeText(item.magnitude) {
                    // "score 0.0654" rather than a bare number read aloud with no
                    // idea what it measures. Composed into a String first: an
                    // interpolated literal passed straight to accessibilityLabel
                    // would be taken as a localization key.
                    let spoken = "\(String(localized: "score")) \(magnitude)"
                    Text(magnitude)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(spoken)
                }
            }
            if let action {
                action
            }
            provenanceDisclosure
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Status

    /// Settled vs awaiting-a-call, by SYMBOL first. Color is added on top but is
    /// never the only signal — a colour-blind or grayscale reader still sees two
    /// different glyphs, and VoiceOver reads the label.
    private var statusSymbol: some View {
        Image(systemName: item.status == .proposed
            ? "questionmark.circle"
            : "checkmark.circle")
            .foregroundStyle(item.status == .proposed ? .orange : .secondary)
            .accessibilityLabel(Self.statusLabel(item.status))
    }

    nonisolated static func statusLabel(_ status: ReviewItemStatus) -> String {
        switch status {
        case .recorded: return String(localized: "Recorded")
        case .proposed: return String(localized: "Proposed, awaiting your review")
        }
    }

    // MARK: Magnitude

    /// The lens's own score, or nil when the surface emitted none.
    ///
    /// Four fraction digits: momentum and centrality values on a real estate run
    /// to 0.0654 and 0.0176 (G1's live capture), so fewer digits would collapse
    /// distinct rows to the same displayed number. Through `NumberFormatter` per
    /// localization rule 2 — a decimal separator is locale-specific.
    ///
    /// NOT a percentage. `magnitude` is whatever the lens computed
    /// (`ReviewModels.swift`: "The surface's own ranking number … Never computed
    /// here"), so it is shown as the bare number it is.
    nonisolated static func magnitudeText(_ magnitude: Double?) -> String? {
        guard let magnitude else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: magnitude))
    }

    // MARK: Provenance

    /// "Where did this come from?" answered without a second query. G1 makes
    /// provenance mandatory on every item precisely so this disclosure can
    /// exist; it is the "inspectable" half of the roadmap's promise. Collapsed
    /// by default so a dense report stays readable.
    private var provenanceDisclosure: some View {
        DisclosureGroup(String(localized: "Where this came from")) {
            VStack(alignment: .leading, spacing: 4) {
                // The registered ARIA tool name — an identifier, not UI copy.
                Text(item.provenance.surface.rawValue)
                    .font(.caption2.monospaced())
                if !item.provenance.arguments.isEmpty {
                    Text(Self.argumentsText(item.provenance.arguments))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(item.provenance.responseLine)   // verbatim substrate output
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .font(.caption)
    }

    /// `key=value` pairs, key-sorted so the same call always renders the same
    /// text (a dictionary's own order is not stable across runs).
    nonisolated static func argumentsText(_ arguments: [String: String]) -> String {
        arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "  ")
    }
}
