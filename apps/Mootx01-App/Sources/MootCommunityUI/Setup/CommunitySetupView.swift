import SwiftUI

public struct CommunitySetupView: View {
    @Bindable private var model: CommunitySetupModel

    public init(model: CommunitySetupModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.state {
            case .checking:
                ProgressView(String(localized: "Checking your estate…"))
            case .needsCreation:
                creationView
            case .chooseExisting(let estates):
                existingView(estates)
            case .missingKey(let estate, let choices):
                recoveryView(
                    title: String(localized: "Estate key is missing"),
                    detail: estate.name,
                    choices: choices
                )
            case .corrupt(let estate, let diagnosis, let choices):
                recoveryView(
                    title: String(localized: "Estate needs recovery"),
                    detail: estate.name,
                    explanation: String(localized: "This estate could not be opened safely and needs recovery."),
                    // The daemon's diagnosis is CORE-03-bounded prose, but it
                    // is still wire content: keep it as a labeled, selectable
                    // detail rather than the primary explanation (R-C10).
                    technicalDetail: String(localized: "Reported diagnosis: \(diagnosis)"),
                    choices: choices
                )
            case .incompatible(let estate, let reason):
                messageView(
                    title: String(localized: "Estate version is incompatible"),
                    detail: String(localized: "\(estate.name) cannot open because its version is not compatible with this app."),
                    // The wire reason stays available behind a label (R-C11).
                    technicalDetail: String(localized: "Reported reason: \(reason)")
                )
            case .migrationRequired(let plan):
                migrationPlanView(plan)
            case .migrating(let progress):
                migrationProgressView(progress)
            case .ready(let receipt):
                ContentUnavailableView(
                    String(localized: "Estate ready"),
                    systemImage: "checkmark.seal",
                    description: Text(receipt.estate.name)
                )
            case .cancelled(let resumable):
                messageView(
                    title: String(localized: "Setup cancelled"),
                    detail: resumable ? String(localized: "You can resume setup safely.") : String(localized: "Setup cannot be resumed.")
                )
            case .blocked(let reason):
                // The daemon's reason code becomes a human sentence; the
                // exact code stays as a labeled, selectable detail (R-C13).
                let presented = CommunityDaemonReason(code: reason)
                messageView(
                    title: String(localized: "Setup unavailable"),
                    detail: presented.explanation,
                    technicalDetail: presented.technicalDetail
                )
            }
        }
        .padding(28)
        .task { if case .checking = model.state { await model.refresh() } }
        .confirmationDialog(
            String(localized: "Confirm destructive recovery"),
            isPresented: Binding(
                get: { model.pendingDestructiveChoice != nil },
                set: { if !$0 { model.dismissDestructiveRecovery() } }
            ),
            titleVisibility: .visible
        ) {
            if let choice = model.pendingDestructiveChoice {
                Button(choice.title, role: .destructive) {
                    Task { await model.confirmDestructiveRecovery() }
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    model.dismissDestructiveRecovery()
                }
            }
        } message: {
            Text(model.pendingDestructiveChoice?.consequence ?? "")
        }
    }

    private var creationView: some View {
        Form {
            Section(String(localized: "Create your estate")) {
                TextField(String(localized: "Estate name"), text: $model.newEstateName)
                Button(String(localized: "Create Estate")) { Task { await model.create() } }
                    .disabled(model.isWorking || model.newEstateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func existingView(_ estates: [CommunityEstateSummary]) -> some View {
        List(estates) { estate in
            Button { Task { await model.open(estate) } } label: {
                VStack(alignment: .leading) {
                    Text(estate.name).font(.headline)
                    // Labeled: the bare value is persistence vocabulary (R-C9).
                    Text(String(localized: "Schema version \(estate.schemaVersion)"))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model.isWorking)
        }
        .navigationTitle(String(localized: "Open an estate"))
    }

    private func recoveryView(
        title: String,
        detail: String,
        explanation: String? = nil,
        technicalDetail: String? = nil,
        choices: [CommunityRecoveryChoice]
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary)
            if let explanation {
                Text(explanation)
            }
            // Wire-supplied technical content is labeled by the caller and
            // selectable so a support request can carry the daemon's exact
            // words without them being the primary display language.
            if let technicalDetail {
                Text(technicalDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ForEach(choices) { choice in
                Button(choice.title, role: choice.isDestructive ? .destructive : nil) {
                    Task { await model.chooseRecovery(choice) }
                }
                Text(choice.consequence).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func migrationPlanView(_ plan: CommunityMigrationPlan) -> some View {
        Form {
            LabeledContent(String(localized: "Estate"), value: plan.estate.name)
            LabeledContent(String(localized: "From"), value: plan.sourceVersion)
            LabeledContent(String(localized: "To"), value: plan.targetVersion)
            Text(plan.expectedEffect)
            Button(String(localized: "Begin Migration")) { Task { await model.migrate(plan) } }
                .disabled(model.isWorking)
        }
        .formStyle(.grouped)
    }

    private func migrationProgressView(_ progress: CommunityMigrationProgress) -> some View {
        VStack(spacing: 16) {
            ProgressView(
                value: Double(progress.completedUnits),
                total: Double(max(progress.totalUnits, 1))
            )
            // Labeled progress (R-C12). The contract names the counted things
            // only as generic "units", so the copy stays noun-free rather
            // than inventing a unit the wire does not carry.
            Text(String(localized: "Migration progress: \(progress.completedUnits) of \(progress.totalUnits) completed"))
            Button(String(localized: "Cancel Migration"), role: .cancel) {
                Task { await model.cancelMigration(progress) }
            }
        }
        .frame(maxWidth: 480)
    }

    private func messageView(
        title: String,
        detail: String,
        technicalDetail: String? = nil
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(detail)
        } actions: {
            // Labeled, selectable wire detail — never the primary language.
            if let technicalDetail {
                Text(technicalDetail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
