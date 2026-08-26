import SwiftUI

// MARK: - TransferView  (APP-06 — Community Import/Export Workflow)
//
// macOS-only SwiftUI surface for APP-06.
// Renders daemon-supplied state through an injected TransferModel.
// No business logic lives here — the model is the sole transformation layer.
//
// Accessibility: every interactive control carries an accessibility label;
// refused-plan states carry an accessibility value with the daemon reason;
// disabled controls include an accessibility hint explaining the prerequisite.
// String(localized:) for all display strings — zero unlocalized text.
//
// PLAN-BEFORE-MUTATION: the execute buttons are disabled whenever
// model.canExecuteImport / model.canExecuteExport is false. The view never
// evaluates plan.executionPermitted itself — it reads the model's gate.
//
// Policy-ineligible content discipline (requirement 4): the export plan
// section renders policyExclusionCount in a dedicated "Excluded" row and
// estimatedTransferCount in a separate "Will export" row. They are never
// added or merged in the view.

#if os(macOS)
@MainActor
public struct TransferView: View {

    // MARK: - Mode

    /// Which workflow the user is currently viewing.
    enum TransferMode: String, CaseIterable {
        case importMode = "import"
        case exportMode = "export"
    }

    // @Bindable so future two-way bindings compile cleanly. All current
    // mutations flow through async model methods.
    @Bindable var model: TransferModel
    @State private var selectedMode: TransferMode = .importMode

    public init(model: TransferModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "transfer.root.label"))
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .padding([.top, .horizontal])
            modePicker
            Divider()
            Group {
                switch selectedMode {
                case .importMode: importSection
                case .exportMode: exportSection
                }
            }
            .padding()
        }
        .accessibilityLabel(String(localized: "transfer.root.label"))
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker(
            String(localized: "transfer.mode.picker.label"),
            selection: $selectedMode
        ) {
            Text(String(localized: "transfer.mode.import.label"))
                .tag(TransferMode.importMode)
            Text(String(localized: "transfer.mode.export.label"))
                .tag(TransferMode.exportMode)
        }
        .pickerStyle(.segmented)
        .padding()
        .accessibilityLabel(String(localized: "transfer.mode.picker.accessibility"))
    }

    // MARK: - Import section

    @ViewBuilder
    private var importSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sourceSelectionGroup
            if model.importPlan != nil {
                importPlanGroup
            }
            importJobGroup
            importControlsGroup
        }
    }

    // Source selection

    private var sourceSelectionGroup: some View {
        GroupBox(label: Text(String(localized: "transfer.import.source.heading"))) {
            VStack(alignment: .leading, spacing: 8) {
                sourceStatusRow
                Button(String(localized: "transfer.import.select.source.button")) {
                    Task { await model.selectImportSource() }
                }
                .disabled(model.isOperationInFlight)
                .accessibilityLabel(String(localized: "transfer.import.select.source.accessibility"))
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var sourceStatusRow: some View {
        switch model.importSourceOutcome {
        case .none:
            Text(String(localized: "transfer.import.source.none"))
                .foregroundStyle(.secondary)
                .accessibilityValue(String(localized: "transfer.import.source.none.value"))
        case .selected(let url, let format):
            VStack(alignment: .leading, spacing: 2) {
                // Filename only — no raw path exposed across the UI surface
                // (CONTRACT-08: no raw contents across the port boundary).
                Text(url.lastPathComponent)
                    .font(.body)
                Text(format.recognized
                     ? String(localized: "transfer.format.recognized \(format.name)")
                     : String(localized: "transfer.format.unrecognized \(format.name)"))
                    .font(.caption)
                    .foregroundStyle(format.recognized ? Color.primary : Color.red)
                    .accessibilityLabel(
                        format.recognized
                        ? String(localized: "transfer.format.recognized.accessibility \(format.name)")
                        : String(localized: "transfer.format.unrecognized.accessibility \(format.name)")
                    )
            }
        case .cancelled:
            Text(String(localized: "transfer.import.source.cancelled"))
                .foregroundStyle(.secondary)
        case .denied(let reason):
            Text(String(localized: "transfer.import.source.denied"))
                .foregroundStyle(.red)
                .accessibilityValue(reason)
        }
    }

    // Import plan

    private var importPlanGroup: some View {
        GroupBox(label: Text(String(localized: "transfer.import.plan.heading"))) {
            VStack(alignment: .leading, spacing: 8) {
                if let plan = model.importPlan {
                    planFieldsView(plan: plan, direction: .import)
                    Button(String(localized: "transfer.import.plan.refresh.button")) {
                        Task {
                            await model.selectImportSource()
                            await model.planImport()
                        }
                    }
                    .disabled(model.isOperationInFlight)
                    .accessibilityLabel(
                        String(localized: "transfer.import.plan.refresh.accessibility")
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // Import job

    @ViewBuilder
    private var importJobGroup: some View {
        if model.importJobID != nil {
            GroupBox(label: Text(String(localized: "transfer.import.job.heading"))) {
                VStack(alignment: .leading, spacing: 8) {
                    importJobStateView
                    jobStatusRefreshOutcomeView(model.lastImportJobStatusOutcome)
                    Button(String(localized: "transfer.import.job.refresh.button")) {
                        Task { await model.refreshImportJobStatus() }
                    }
                    .disabled(model.isLoadingJobStatus)
                    .accessibilityLabel(
                        String(localized: "transfer.import.job.refresh.accessibility")
                    )
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var importJobStateView: some View {
        switch model.importJobState {
        case .none:
            Text(String(localized: "transfer.job.state.loading"))
                .foregroundStyle(.secondary)
        case .queued:
            Text(String(localized: "transfer.job.state.queued"))
                .accessibilityValue(String(localized: "transfer.job.state.queued"))
        case .running(let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "transfer.job.state.running"))
                if let p = progress {
                    // Progress: daemon-supplied counts rendered verbatim.
                    Text(String(localized: "transfer.job.progress \(p.processed) \(p.total)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            String(localized: "transfer.job.progress.accessibility \(p.processed) \(p.total)")
                        )
                }
            }
        case .waiting(let reason):
            // Distinct from queued — requirement 5 (six states surfaced).
            Text(String(localized: "transfer.job.state.waiting"))
                .accessibilityValue(reason)
        case .completed(let counts, let receipt):
            // Requirement 7: all five count fields surfaced; receipt shown.
            countsView(counts: counts, receipt: receipt, complete: true)
        case .failed(let reason, let partial):
            // Requirement 8: partial failure is never rendered as complete success.
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "transfer.job.state.failed"))
                    .foregroundStyle(.red)
                    .accessibilityValue(reason)
                if let counts = partial {
                    Text(String(localized: "transfer.job.state.failed.partial"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    countsView(counts: counts, receipt: nil, complete: false)
                }
            }
        case .cancelled(let stage):
            // Requirement 6: stage rendered verbatim — three distinct cases.
            cancellationStageView(stage: stage)
        }
    }

    // Import controls

    @ViewBuilder
    private var importControlsGroup: some View {
        HStack(spacing: 12) {
            Button(String(localized: "transfer.import.plan.button")) {
                Task { await model.planImport() }
            }
            .disabled(model.isOperationInFlight || model.importSourceOutcome == nil)
            .accessibilityLabel(String(localized: "transfer.import.plan.button.accessibility"))
            .accessibilityHint(
                model.importSourceOutcome == nil
                ? String(localized: "transfer.import.plan.button.hint.no.source")
                : ""
            )

            Button(String(localized: "transfer.import.execute.button")) {
                Task { await model.executeImport() }
            }
            // PLAN-BEFORE-MUTATION: disabled whenever the model gate is false.
            // The view never evaluates executionPermitted itself.
            .disabled(model.isOperationInFlight || !model.canExecuteImport)
            .accessibilityLabel(String(localized: "transfer.import.execute.button.accessibility"))
            .accessibilityHint(
                !model.canExecuteImport
                ? String(localized: "transfer.import.execute.button.hint.no.plan")
                : ""
            )

            if model.importJobID != nil && !model.isImportComplete {
                Button(String(localized: "transfer.import.cancel.button")) {
                    Task { await model.cancelImportJob() }
                }
                .disabled(model.isOperationInFlight)
                .foregroundStyle(.red)
                .accessibilityLabel(
                    String(localized: "transfer.import.cancel.button.accessibility")
                )
            }
        }

        // FIX 3: Import plan failure surfacing. When planning fails the plan group
        // is hidden (importPlan is nil) so failure is otherwise invisible.
        if case .failed(let reason) = model.lastImportPlanOutcome {
            Text(String(localized: "transfer.outcome.import.plan.failed \(reason)"))
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityValue(reason)
        }

        // FIX 3: Import execute outcome surfacing.
        // .submitted leads to a job ID and status display above; the user sees it.
        // .denied and .failed are currently invisible — the button looks like it did
        // nothing. The permission-loss-at-execute case (.denied) is especially critical
        // to surface because the user prepared a plan and expects a job to start.
        if let outcome = model.lastImportExecuteOutcome {
            switch outcome {
            case .submitted:
                EmptyView()  // Job section already shows the submitted state.
            case .denied(let reason):
                Label(
                    String(localized: "transfer.outcome.import.execute.denied \(reason)"),
                    systemImage: "hand.raised"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel(
                    String(localized: "transfer.outcome.import.execute.denied.a11y \(reason)")
                )
                .accessibilityValue(reason)
            case .failed(let reason):
                Text(String(localized: "transfer.outcome.import.execute.failed \(reason)"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityValue(reason)
            }
        }

        // FIX 3: Cancel outcome failure surfacing near the cancel button.
        // .cancelled advances importJobState to .cancelled(stage:) — already shown
        // in the job section. .alreadyComplete triggers a status reload — visible.
        // Only .failed and .notFound need inline feedback.
        if let outcome = model.lastCancelOutcome {
            switch outcome {
            case .cancelled, .alreadyComplete:
                EmptyView()
            case .notFound:
                Text(String(localized: "transfer.outcome.cancel.not.found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text(String(localized: "transfer.outcome.cancel.failed \(reason)"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityValue(reason)
            }
        }
    }

    // MARK: - Export section

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            exportDestinationGroup
            exportScopeGroup
            if model.exportPlan != nil {
                exportPlanGroup
            }
            exportJobGroup
            exportControlsGroup
        }
    }

    private var exportDestinationGroup: some View {
        GroupBox(label: Text(String(localized: "transfer.export.destination.heading"))) {
            VStack(alignment: .leading, spacing: 8) {
                exportDestinationStatusRow
                Button(String(localized: "transfer.export.select.destination.button")) {
                    Task { await model.selectExportDestination() }
                }
                .disabled(model.isOperationInFlight)
                .accessibilityLabel(
                    String(localized: "transfer.export.select.destination.accessibility")
                )
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var exportDestinationStatusRow: some View {
        switch model.exportDestinationOutcome {
        case .none:
            Text(String(localized: "transfer.export.destination.none"))
                .foregroundStyle(.secondary)
        case .selected(let url):
            Text(url.lastPathComponent)
        case .cancelled:
            Text(String(localized: "transfer.export.destination.cancelled"))
                .foregroundStyle(.secondary)
        case .denied(let reason):
            Text(String(localized: "transfer.export.destination.denied"))
                .foregroundStyle(.red)
                .accessibilityValue(reason)
        }
    }

    private var exportScopeGroup: some View {
        GroupBox(label: Text(String(localized: "transfer.export.scope.heading"))) {
            VStack(alignment: .leading, spacing: 8) {
                exportScopeStatusRow
                Button(String(localized: "transfer.export.select.scope.button")) {
                    Task { await model.selectExportScope() }
                }
                .disabled(model.isOperationInFlight)
                .accessibilityLabel(
                    String(localized: "transfer.export.select.scope.accessibility")
                )
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var exportScopeStatusRow: some View {
        switch model.exportScopeOutcome {
        case .none:
            Text(String(localized: "transfer.export.scope.none"))
                .foregroundStyle(.secondary)
        case .selected(_, let count, let description):
            VStack(alignment: .leading, spacing: 2) {
                Text(description)
                Text(String(localized: "transfer.export.scope.count \(count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .cancelled:
            Text(String(localized: "transfer.export.scope.cancelled"))
                .foregroundStyle(.secondary)
        }
    }

    private var exportPlanGroup: some View {
        GroupBox(label: Text(String(localized: "transfer.export.plan.heading"))) {
            if let plan = model.exportPlan {
                planFieldsView(plan: plan, direction: .export)
                    .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var exportJobGroup: some View {
        if model.exportJobID != nil {
            GroupBox(label: Text(String(localized: "transfer.export.job.heading"))) {
                VStack(alignment: .leading, spacing: 8) {
                    exportJobStateView
                    jobStatusRefreshOutcomeView(model.lastExportJobStatusOutcome)
                    Button(String(localized: "transfer.export.job.refresh.button")) {
                        Task { await model.refreshExportJobStatus() }
                    }
                    .disabled(model.isLoadingJobStatus)
                    .accessibilityLabel(
                        String(localized: "transfer.export.job.refresh.accessibility")
                    )
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var exportJobStateView: some View {
        switch model.exportJobState {
        case .none:
            Text(String(localized: "transfer.job.state.loading"))
                .foregroundStyle(.secondary)
        case .queued:
            Text(String(localized: "transfer.job.state.queued"))
        case .running(let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "transfer.job.state.running"))
                if let p = progress {
                    Text(String(localized: "transfer.job.progress \(p.processed) \(p.total)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .waiting(let reason):
            Text(String(localized: "transfer.job.state.waiting"))
                .accessibilityValue(reason)
        case .completed(let counts, let receipt):
            countsView(counts: counts, receipt: receipt, complete: true)
        case .failed(let reason, let partial):
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "transfer.job.state.failed"))
                    .foregroundStyle(.red)
                    .accessibilityValue(reason)
                if let counts = partial {
                    countsView(counts: counts, receipt: nil, complete: false)
                }
            }
        case .cancelled(let stage):
            cancellationStageView(stage: stage)
        }
    }

    @ViewBuilder
    private var exportControlsGroup: some View {
        HStack(spacing: 12) {
            Button(String(localized: "transfer.export.plan.button")) {
                Task { await model.planExport() }
            }
            .disabled(
                model.isOperationInFlight
                || model.exportDestinationOutcome == nil
                || model.exportScopeOutcome == nil
            )
            .accessibilityLabel(String(localized: "transfer.export.plan.button.accessibility"))

            Button(String(localized: "transfer.export.execute.button")) {
                Task { await model.executeExport() }
            }
            // PLAN-BEFORE-MUTATION: disabled whenever model gate is false.
            .disabled(model.isOperationInFlight || !model.canExecuteExport)
            .accessibilityLabel(String(localized: "transfer.export.execute.button.accessibility"))
            .accessibilityHint(
                !model.canExecuteExport
                ? String(localized: "transfer.export.execute.button.hint.no.plan")
                : ""
            )

            if model.exportJobID != nil && !model.isExportComplete {
                Button(String(localized: "transfer.export.cancel.button")) {
                    Task { await model.cancelExportJob() }
                }
                .disabled(model.isOperationInFlight)
                .foregroundStyle(.red)
                .accessibilityLabel(
                    String(localized: "transfer.export.cancel.button.accessibility")
                )
            }
        }

        // FIX 3: Export plan failure surfacing. Mirrors the import pattern.
        if case .failed(let reason) = model.lastExportPlanOutcome {
            Text(String(localized: "transfer.outcome.export.plan.failed \(reason)"))
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityValue(reason)
        }

        // FIX 3: Export execute outcome surfacing.
        // .denied is the permission-loss-at-execute case — invisible without this block.
        if let outcome = model.lastExportExecuteOutcome {
            switch outcome {
            case .submitted:
                EmptyView()  // Job section already shows the submitted state.
            case .denied(let reason):
                Label(
                    String(localized: "transfer.outcome.export.execute.denied \(reason)"),
                    systemImage: "hand.raised"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel(
                    String(localized: "transfer.outcome.export.execute.denied.a11y \(reason)")
                )
                .accessibilityValue(reason)
            case .failed(let reason):
                Text(String(localized: "transfer.outcome.export.execute.failed \(reason)"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityValue(reason)
            }
        }

        // FIX 3: Cancel outcome failure surfacing (export side).
        // lastCancelOutcome is shared between import and export. The cancel button
        // is only visible while a job is running, so whichever job the cancel applied
        // to, its outcome is shown here if it's a failure.
        if let outcome = model.lastCancelOutcome {
            switch outcome {
            case .cancelled, .alreadyComplete:
                EmptyView()
            case .notFound:
                Text(String(localized: "transfer.outcome.cancel.not.found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text(String(localized: "transfer.outcome.cancel.failed \(reason)"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityValue(reason)
            }
        }
    }

    @ViewBuilder
    private func jobStatusRefreshOutcomeView(_ outcome: TransferJobStatusOutcome?) -> some View {
        switch outcome {
        case .status, .none:
            EmptyView()
        case .notFound:
            Text(String(localized: "transfer.outcome.job.status.not.found"))
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed(let reason):
            Text(String(localized: "transfer.outcome.job.status.failed \(reason)"))
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityValue(reason)
        }
    }

    // MARK: - Shared sub-views

    // MARK: Plan fields
    //
    // Renders all six CONTRACT-06 plan fields for import or export.
    // Policy-ineligible content discipline: policyExclusionCount is rendered
    // in a dedicated "Excluded" row, never added to estimatedTransferCount.
    // The view never merges these two values.

    private enum TransferDirection { case `import`, export }

    @ViewBuilder
    private func planFieldsView(plan: TransferPlan, direction: TransferDirection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Format: recognized/unrecognized status.
            HStack {
                Text(String(localized: "transfer.plan.format.label"))
                    .foregroundStyle(.secondary)
                Text(plan.format.name)
                if !plan.format.recognized {
                    // Unrecognized format is a refusal signal — surface prominently.
                    Text(String(localized: "transfer.plan.format.unrecognized.badge"))
                        .foregroundStyle(.red)
                        .font(.caption)
                        .accessibilityLabel(
                            String(localized: "transfer.plan.format.unrecognized.accessibility")
                        )
                }
            }
            .accessibilityElement(children: .combine)

            // Candidate total.
            planRow(
                label: String(localized: "transfer.plan.candidates.label"),
                value: "\(plan.candidateCount)"
            )

            // Conflicts.
            if plan.conflictCount > 0 {
                planRow(
                    label: String(localized: "transfer.plan.conflicts.label"),
                    value: "\(plan.conflictCount)",
                    valueStyle: .orange
                )
            }

            // Invalid/malformed.
            if plan.invalidCount > 0 {
                planRow(
                    label: String(localized: "transfer.plan.invalid.label"),
                    value: "\(plan.invalidCount)",
                    valueStyle: .orange
                )
            }

            // Policy exclusions — structurally separate from estimatedTransferCount.
            // Never added to "Will transfer" row. Requirement 4.
            if plan.policyExclusionCount > 0 {
                planRow(
                    label: String(localized: "transfer.plan.excluded.label"),
                    value: "\(plan.policyExclusionCount)",
                    valueStyle: .secondary
                )
            }

            // Estimated effect — does NOT include policyExclusionCount.
            let estimatedKey = direction == .import
                ? "transfer.plan.estimated.import.label"
                : "transfer.plan.estimated.export.label"
            planRow(
                label: String(localized: String.LocalizationValue(estimatedKey)),
                value: "\(plan.estimatedTransferCount)"
            )

            // Execution gate status.
            if !plan.executionPermitted {
                Text(String(localized: "transfer.plan.execution.refused"))
                    .foregroundStyle(.red)
                    .font(.caption)
                    .accessibilityLabel(
                        String(localized: "transfer.plan.execution.refused.accessibility")
                    )
            }
        }
    }

    private func planRow(
        label: String,
        value: String,
        valueStyle: Color = .primary
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(valueStyle)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: Transfer counts
    //
    // Renders all five CONTRACT-06 count fields. Never omits any field.
    // Requirement 8: `complete` drives whether the heading shows success
    // or partial state — the view never infers completion from counts alone.

    @ViewBuilder
    private func countsView(
        counts: TransferCounts,
        receipt: String?,
        complete: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Heading — explicitly set by caller, never inferred from counts.
            Text(complete
                 ? String(localized: "transfer.counts.complete.heading")
                 : String(localized: "transfer.counts.partial.heading"))
                .font(.headline)
                .foregroundStyle(complete ? Color.primary : Color.orange)
                .accessibilityAddTraits(complete ? [] : .isHeader)

            // All five fields — always rendered when counts are available.
            countRow(
                label: String(localized: "transfer.counts.transferred.label"),
                value: counts.transferred
            )
            countRow(
                label: String(localized: "transfer.counts.skipped.label"),
                value: counts.skipped
            )
            countRow(
                label: String(localized: "transfer.counts.conflicted.label"),
                value: counts.conflicted
            )
            // Excluded: privacy/policy exclusions that occurred during execution.
            countRow(
                label: String(localized: "transfer.counts.excluded.label"),
                value: counts.excluded
            )
            if counts.failed > 0 {
                // Failed shown in red when non-zero to make partial failure visible.
                countRow(
                    label: String(localized: "transfer.counts.failed.label"),
                    value: counts.failed,
                    valueStyle: .red
                )
            } else {
                countRow(
                    label: String(localized: "transfer.counts.failed.label"),
                    value: counts.failed
                )
            }

            // Stable receipt (CONTRACT-08) — only present on true completion.
            if let receipt {
                HStack {
                    Text(String(localized: "transfer.counts.receipt.label"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    // Receipt is daemon-issued opaque string; display as monospaced.
                    Text(receipt)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(
                    String(localized: "transfer.counts.receipt.accessibility \(receipt)")
                )
            }
        }
    }

    private func countRow(
        label: String,
        value: Int,
        valueStyle: Color = .primary
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
            Text("\(value)")
                .foregroundStyle(valueStyle)
                .font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: Cancellation stage
    //
    // Requirement 6: three distinct cases rendered verbatim.
    // "After commit" explicitly states work was committed — never collapsed
    // into a single "cancelled" label that could hide committed mutations.

    @ViewBuilder
    private func cancellationStageView(stage: CancellationStage) -> some View {
        switch stage {
        case .beforeCommit:
            // No estate mutation occurred — requirement 4 verified at runtime.
            Text(String(localized: "transfer.cancel.stage.before.commit"))
                .accessibilityLabel(
                    String(localized: "transfer.cancel.stage.before.commit.accessibility")
                )
        case .duringCommit(let partial):
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "transfer.cancel.stage.during.commit"))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(
                        String(localized: "transfer.cancel.stage.during.commit.accessibility")
                    )
                // Show partial counts — requirement 6.
                countsView(counts: partial, receipt: nil, complete: false)
            }
        case .afterCommit(let counts):
            VStack(alignment: .leading, spacing: 4) {
                // Explicitly states work was committed before cancellation.
                Text(String(localized: "transfer.cancel.stage.after.commit"))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(
                        String(localized: "transfer.cancel.stage.after.commit.accessibility")
                    )
                countsView(counts: counts, receipt: nil, complete: false)
            }
        }
    }
}
#endif
