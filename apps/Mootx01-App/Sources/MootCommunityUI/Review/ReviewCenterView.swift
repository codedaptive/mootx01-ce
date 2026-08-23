import SwiftUI

// MARK: - ReviewCenterView  (APP-04 — Complete Review Center)
//
// macOS SwiftUI surface for the Review Center feature.
// Driven entirely by ReviewCenterModel — no business logic here.
// All display strings go through String(localized:) per the Community
// localization rule (zero literal UI copy in views).

// MARK: - ReviewCenterView

/// The top-level Review Center view.  Contains a dashboard list and pushes
/// into per-mode session views.  The app-level slot that embeds this view
/// is INTEGRATION-02 (slot ownership is outside this module's boundary).
public struct ReviewCenterView: View {
    @Bindable private var model: ReviewCenterModel

    public init(model: ReviewCenterModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ReviewDashboardView(model: model)
                .navigationTitle(String(localized: "Review Center"))
        }
        .task {
            await model.loadDashboard()
        }
    }
}

// MARK: - ReviewDashboardView

/// Dashboard: lists all three review modes with their daemon-reported status
/// and lets the user navigate into each mode's session view.
struct ReviewDashboardView: View {
    @Bindable var model: ReviewCenterModel

    var body: some View {
        Group {
            if model.isLoadingDashboard {
                ProgressView(String(localized: "Loading review dashboard…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(String(localized: "Loading review dashboard"))
            } else if let state = model.dashboardState {
                dashboardList(state: state)
            } else {
                ContentUnavailableView(
                    String(localized: "Review Center"),
                    systemImage: "checklist",
                    description: Text(String(localized: "Dashboard unavailable"))
                )
                .accessibilityLabel(String(localized: "Dashboard unavailable"))
            }
        }
        .navigationTitle(String(localized: "Reviews"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Refresh")) {
                    Task { await model.loadDashboard() }
                }
                .accessibilityLabel(String(localized: "Refresh review dashboard"))
            }
        }
    }

    @ViewBuilder
    private func dashboardList(state: ReviewDashboardState) -> some View {
        List {
            // Ordered by ReviewSessionKind.allCases — deterministic, no locale sort.
            ForEach(state.orderedModes, id: \.kind) { entry in
                ReviewModeRowView(
                    kind: entry.kind,
                    status: entry.status,
                    model: model
                )
            }
        }
        .accessibilityLabel(String(localized: "Review modes"))
    }
}

// MARK: - ReviewModeRowView

/// One row in the dashboard, showing the mode name, its status badge, and a
/// navigation link into the session view.
private struct ReviewModeRowView: View {
    let kind: ReviewSessionKind
    let status: ReviewModeStatus
    @Bindable var model: ReviewCenterModel

    var body: some View {
        NavigationLink(destination: sessionDestination) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(kindLabel)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(statusLabel)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                statusBadge
            }
            .padding(.vertical, 4)
        }
        // Disable navigation for blocked modes — fail-closed: don't enter a
        // mode the daemon has blocked.
        .disabled(isBlocked)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(statusLabel)
        .accessibilityHint(isBlocked
            ? String(localized: "This review mode is unavailable")
            : String(localized: "Activate to open this review"))
    }

    // MARK: Computed strings — all through String(localized:)

    private var kindLabel: String {
        switch kind {
        case .morning:  String(localized: "Morning Review")
        case .endOfDay: String(localized: "End of Day Review")
        case .weekly:   String(localized: "Weekly Review")
        }
    }

    private var statusLabel: String {
        switch status {
        case .available:             String(localized: "Available")
        case .due:                   String(localized: "Due now")
        case .inProgress:            String(localized: "In progress")
        case .completed:             String(localized: "Completed")
        case .blocked(let reason):   reason
        }
    }

    private var statusColor: Color {
        switch status {
        case .available:   .secondary
        case .due:         .orange
        case .inProgress:  .blue
        case .completed:   .green
        case .blocked:     .red
        }
    }

    private var isBlocked: Bool {
        if case .blocked = status { return true }
        return false
    }

    private var accessibilityLabel: String {
        switch kind {
        case .morning:  String(localized: "Morning Review")
        case .endOfDay: String(localized: "End of Day Review")
        case .weekly:   String(localized: "Weekly Review")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .due:
            Label(String(localized: "Due"), systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .font(.caption)
        case .completed:
            Label(String(localized: "Done"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .inProgress:
            Label(String(localized: "Open"), systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.blue)
                .font(.caption)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var sessionDestination: some View {
        ReviewSessionView(kind: kind, model: model)
    }
}

// MARK: - ReviewSessionView

/// The session view for one review kind. Shows ordered sections, proposed
/// actions, duplicate groups, and a complete button.
struct ReviewSessionView: View {
    let kind: ReviewSessionKind
    @Bindable var model: ReviewCenterModel

    var body: some View {
        Group {
            if model.isLoadingSession {
                ProgressView(String(localized: "Loading review session…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(String(localized: "Loading review session"))
            } else if let session = model.activeSession, session.kind == kind {
                sessionContent(session: session)
            } else if let reason = model.sessionBlockReason {
                ContentUnavailableView(
                    String(localized: "Session Unavailable"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(reason)
                )
                .accessibilityLabel(
                    String(localized: "Session blocked: \(reason)"))
            } else {
                ContentUnavailableView(
                    String(localized: "No Session"),
                    systemImage: "checklist",
                    description: Text(String(localized: "No review session loaded"))
                )
            }
        }
        .navigationTitle(sessionTitle)
        .task {
            await model.loadSession(kind: kind)
        }
    }

    private var sessionTitle: String {
        switch kind {
        case .morning:  String(localized: "Morning Review")
        case .endOfDay: String(localized: "End of Day Review")
        case .weekly:   String(localized: "Weekly Review")
        }
    }

    @ViewBuilder
    private func sessionContent(session: ReviewSession) -> some View {
        // Completion receipt overlay takes priority.
        if let receipt = model.completionReceipt {
            ReviewCompletionReceiptView(receipt: receipt)
        } else {
            List {
                // Ordered sections — daemon order preserved; no re-sort.
                if !session.orderedSections.isEmpty {
                    ForEach(session.orderedSections) { section in
                        ReviewSectionView(section: section)
                    }
                } else {
                    Section {
                        Text(String(localized: "No items in this review"))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                String(localized: "This review has no items"))
                    }
                }

                // Proposed actions section.
                if !session.proposedActions.isEmpty {
                    Section(String(localized: "Proposed Actions")) {
                        ForEach(session.proposedActions) { action in
                            ReviewActionRowView(action: action, model: model)
                        }
                    }
                }

                // Duplicate groups section.
                if !session.duplicateGroups.isEmpty {
                    Section(String(localized: "Duplicate Groups")) {
                        ForEach(session.duplicateGroups) { group in
                            DuplicateGroupRowView(group: group, model: model)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "Complete Review")) {
                        Task { await model.completeSession() }
                    }
                    .accessibilityLabel(String(localized: "Complete this review"))
                }
            }
            // Action outcome alert — surfaces the daemon's outcome without
            // optimistic false success.
            .overlay(alignment: .bottom) {
                if let outcome = model.lastActionOutcome {
                    ActionOutcomeBanner(outcome: outcome) {
                        model.dismissActionOutcome()
                    }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.lastActionOutcome != nil)
            // FIX 2: Completion failure surfacing inside sessionContent.
            // When completeSession() fails the model sets lastCompletionFailureReason
            // but keeps activeSession non-nil, so the outer ReviewSessionView if/else
            // chain never reaches sessionBlockReason. This overlay shows the failure
            // while the session content remains visible so the user can retry.
            .overlay(alignment: .top) {
                if let reason = model.lastCompletionFailureReason {
                    CompletionFailureBanner(reason: reason) {
                        model.dismissCompletionFailure()
                    }
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.lastCompletionFailureReason != nil)
        }
    }
}

// MARK: - ReviewSectionView

private struct ReviewSectionView: View {
    let section: ReviewSessionSection

    var body: some View {
        Section(section.title) {
            if section.items.isEmpty {
                Text(String(localized: "No items in this section"))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        String(localized: "Section \(section.title) has no items"))
            } else {
                ForEach(section.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.subject).font(.body)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        item.detail.isEmpty
                            ? item.subject
                            : "\(item.subject): \(item.detail)")
                }
            }
        }
    }
}

// MARK: - ReviewActionRowView

/// One proposed action row. Shows the expected effect BEFORE the user
/// confirms, satisfying requirement 3. Includes reversal control when
/// the daemon says reversal is available.
private struct ReviewActionRowView: View {
    let action: ReviewAction
    @Bindable var model: ReviewCenterModel

    private var isPending: Bool { model.pendingAction?.id == action.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Expected-effect description — always shown before confirmation.
            Text(action.expectedEffect)
                .font(.body)
                .accessibilityLabel(
                    String(localized: "Action: \(action.expectedEffect)"))

            HStack(spacing: 12) {
                // Apply button. Disabled while another action is in flight.
                Button(String(localized: "Apply")) {
                    model.selectAction(action)
                    Task { await model.applyPendingAction() }
                }
                .disabled(model.isApplyingAction)
                .accessibilityLabel(
                    String(localized: "Apply action: \(action.expectedEffect)"))

                // Reversal control — only visible when daemon says reversal
                // remains available. The view never infers availability itself.
                if action.isReversible && action.reversalAvailable {
                    Button(String(localized: "Reverse")) {
                        Task { await model.reverseAction(action) }
                    }
                    .disabled(model.isApplyingAction)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(
                        String(localized: "Reverse action: \(action.expectedEffect)"))
                    .accessibilityHint(
                        String(localized: "Reversal is currently available"))
                } else if action.isReversible && !action.reversalAvailable {
                    // Disabled reversal button shows the feature exists but is
                    // not currently available — honest state, not hidden.
                    Button(String(localized: "Reverse")) {}
                        .disabled(true)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            String(localized: "Reverse action: \(action.expectedEffect)"))
                        .accessibilityValue(
                            String(localized: "Reversal not available"))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - DuplicateGroupRowView

/// One duplicate group row. Shows which records are involved and presents
/// only the daemon-approved resolution choices (requirement 6).
private struct DuplicateGroupRowView: View {
    let group: DuplicateGroup
    @Bindable var model: ReviewCenterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.reason)
                .font(.subheadline)

            // Involved records — surface them so the user can inspect.
            Text(involvedLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    String(localized: "Duplicate records: \(involvedLabel)"))

            // Only daemon-approved choices — no model-invented alternatives.
            Text(String(localized: "Resolution choices:"))
                .font(.subheadline.weight(.medium))

            ForEach(group.resolutionChoices) { choice in
                Button(choice.description) {
                    model.pendingGroupID = group.id
                    model.pendingChoiceID = choice.id
                    Task {
                        await model.resolveGroup(groupID: group.id, choiceID: choice.id)
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    String(localized: "Resolution: \(choice.description)"))
                .accessibilityHint(
                    String(localized: "Submits this choice to the daemon"))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var involvedLabel: String {
        let ids = group.involvedRecordIDs
            .map { $0.uuidString.prefix(8) }
            .joined(separator: ", ")
        return String(localized: "Records: \(ids)")
    }
}

// MARK: - ReviewCompletionReceiptView

/// Shown when a session has been completed. Displays the daemon's receipt
/// (requirement 8).
private struct ReviewCompletionReceiptView: View {
    let receipt: ReviewCompletionReceipt

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text(String(localized: "Review Completed"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            // Completion time from the daemon's receipt.
            Text(Self.dateFormatter.string(from: receipt.completedAt))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    String(localized: "Completed at \(Self.dateFormatter.string(from: receipt.completedAt))"))

            if !receipt.summary.isEmpty {
                Text(receipt.summary)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .accessibilityLabel(receipt.summary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - CompletionFailureBanner

/// FIX 2: Non-modal banner surfacing a completion failure while the session
/// remains visible. Reuses the same material/rounded-rect pattern as
/// ActionOutcomeBanner so both banners are visually consistent. Shown at
/// the top of sessionContent (action outcomes anchor at the bottom) to
/// prevent overlap when both are present simultaneously.
private struct CompletionFailureBanner: View {
    let reason: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "review.completion.failed.title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(reason)
            }
            Spacer()
            Button(String(localized: "Dismiss")) { dismiss() }
                .font(.subheadline)
                .accessibilityLabel(String(localized: "Dismiss completion failure"))
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(localized: "review.completion.failed.a11y \(reason)")
        )
    }
}

// MARK: - ActionOutcomeBanner

/// Non-modal banner surfacing the daemon's action outcome — never optimistic
/// false success (requirement 4).
private struct ActionOutcomeBanner: View {
    let outcome: ReviewActionOutcome
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: outcomeIcon)
                .foregroundStyle(outcomeColor)
                .accessibilityHidden(true)
            Text(outcomeMessage)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .accessibilityLabel(outcomeMessage)
            Spacer()
            Button(String(localized: "Dismiss")) { dismiss() }
                .font(.subheadline)
                .accessibilityLabel(String(localized: "Dismiss action outcome"))
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    // Every case is named and colored distinctly — the user never sees
    // a success indicator for a non-success outcome.
    private var outcomeIcon: String {
        switch outcome {
        case .applied:        "checkmark.circle.fill"
        case .alreadyApplied: "checkmark.circle"
        case .conflict:       "exclamationmark.triangle.fill"
        case .staleSession:   "arrow.clockwise.circle.fill"
        case .refused:        "nosign"
        case .failed:         "xmark.circle.fill"
        }
    }

    private var outcomeColor: Color {
        switch outcome {
        case .applied:        .green
        case .alreadyApplied: .blue
        case .conflict:       .orange
        case .staleSession:   .orange
        case .refused:        .red
        case .failed:         .red
        }
    }

    private var outcomeMessage: String {
        switch outcome {
        case .applied:
            String(localized: "Action applied")
        case .alreadyApplied:
            String(localized: "Already applied")
        case .conflict(let reason):
            String(localized: "Conflict: \(reason)")
        case .staleSession:
            String(localized: "Session is stale — please reconnect")
        case .refused(let reason):
            String(localized: "Refused: \(reason)")
        case .failed(let reason):
            String(localized: "Failed: \(reason)")
        }
    }
}

// MARK: - ReviewActionOutcome Identifiable shim
//
// SwiftUI animation uses `value: model.lastActionOutcome != nil` (Bool), so
// the outcome itself doesn't need Identifiable here. The animation expression
// avoids comparing ReviewActionOutcome directly in the view.

extension ReviewCenterModel {
    // Exposes the outcome nil-check for the banner animation binding, keeping
    // the model's `lastActionOutcome` setter private.
    var hasActionOutcome: Bool { lastActionOutcome != nil }
}
