import SwiftUI

// MARK: - ObsidianSyncView  (APP-05 — Obsidian Synchronization Controls)
//
// macOS-only SwiftUI surface for APP-05.
// Renders daemon-supplied state through an injected ObsidianSyncModel.
// No business logic lives here — the model is the sole transformation layer.
//
// Accessibility: every interactive control carries an accessibility label;
// blocked and failed states carry an accessibility value with the daemon reason.
// String(localized:) for all display strings — zero unlocalized text.
//
// The `.task` modifier loads both status and authorization on appear, matching
// the model's dual-load requirement. The model's `isOperationInFlight` flag
// is respected to disable all controls during in-flight operations.

#if os(macOS)
@MainActor
public struct ObsidianSyncView: View {

    // @Bindable so future two-way bindings (e.g. pending selection draft) compile
    // cleanly. All current mutations flow through async model methods.
    @Bindable var model: ObsidianSyncModel

    public init(model: ObsidianSyncModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            authorizationSection
            syncStatusSection
            controlsSection
        }
        .padding()
        .task {
            await model.loadStatus()
            await model.loadAuthorizationState()
        }
    }

    // MARK: - Authorization section (requirement 2)

    @ViewBuilder
    private var authorizationSection: some View {
        GroupBox(label: Text(String(localized: "obsidian.section.authorization"))) {
            VStack(alignment: .leading, spacing: 8) {
                if let authState = model.authorizationState {
                    switch authState {
                    case .valid(_, let name):
                        Label(
                            String(localized: "obsidian.auth.valid \(name)"),
                            systemImage: "checkmark.circle"
                        )
                        .accessibilityLabel(
                            String(localized: "obsidian.auth.valid.a11y \(name)")
                        )
                    case .missing:
                        Label(
                            String(localized: "obsidian.auth.missing"),
                            systemImage: "questionmark.circle"
                        )
                        .foregroundStyle(.secondary)
                    case .needsRenewal(_, let name, let reason):
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                String(localized: "obsidian.auth.needs.renewal \(name)"),
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                // Vault selection control — available for initial selection
                // and for replacement of an existing vault (requirement 1).
                Button(String(localized: "obsidian.action.select.vault")) {
                    Task { await model.selectVault() }
                }
                .accessibilityLabel(String(localized: "obsidian.action.select.vault.a11y"))
                .disabled(model.isOperationInFlight)

                // FIX 1: Surface vault selection denial verbatim.
                // .selected is visible in the auth-state display above;
                // .cancelled is self-evident (picker dismissed without action).
                // Only .denied requires explicit inline feedback — the user
                // would otherwise see no indication that their selection was
                // refused by the daemon.
                if case .denied(let reason) = model.lastVaultSelectionOutcome {
                    Label(
                        String(localized: "obsidian.outcome.vault.denied \(reason)"),
                        systemImage: "hand.raised"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(
                        String(localized: "obsidian.outcome.vault.denied.a11y \(reason)")
                    )
                    .accessibilityValue(reason)
                }
            }
        }
    }

    // MARK: - Sync status section (requirement 4: nine distinct states)

    @ViewBuilder
    private var syncStatusSection: some View {
        GroupBox(label: Text(String(localized: "obsidian.section.status"))) {
            if model.isLoadingStatus {
                ProgressView()
                    .accessibilityLabel(String(localized: "obsidian.status.loading.a11y"))
            } else if let status = model.syncStatus {
                VStack(alignment: .leading, spacing: 4) {
                    syncStatusContent(status)
                    // FIX 5 (CONTRACT-05 losslessness): render the last successful
                    // checkpoint regardless of current status so interrupted/waiting/
                    // paused/synchronizing states do not silently drop it.
                    // The .idle case shows it via its associated value above; we
                    // suppress the footer there to avoid a duplicate display.
                    if let cp = model.lastCheckpoint, !status.isIdle {
                        Text(
                            String(
                                localized:
                                    "obsidian.status.checkpoint \(cp.recordCount)"
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            String(
                                localized:
                                    "obsidian.status.checkpoint.a11y \(cp.recordCount)"
                            )
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func syncStatusContent(_ status: ObsidianSyncStatus) -> some View {
        switch status {
        case .starting:
            ProgressView(String(localized: "obsidian.status.starting"))

        case .scanning:
            ProgressView(String(localized: "obsidian.status.scanning"))

        case .synchronizing(let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(String(localized: "obsidian.status.synchronizing"))
                // Requirement 5: surface outstanding work when daemon supplies it.
                if let p = progress {
                    Text(
                        String(
                            localized:
                                "obsidian.status.progress \(p.pendingCount) \(p.totalCount)"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

        case .idle(let checkpoint):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "obsidian.status.idle"),
                    systemImage: "checkmark.circle"
                )
                // Requirement 5: surface last successful checkpoint when daemon
                // provides it.
                if let cp = checkpoint {
                    Text(
                        String(localized: "obsidian.status.checkpoint \(cp.recordCount)")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

        case .waiting(let until):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "obsidian.status.waiting"),
                    systemImage: "clock"
                )
                if let d = until {
                    Text(d, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .paused:
            Label(
                String(localized: "obsidian.status.paused"),
                systemImage: "pause.circle"
            )

        case .interrupted(let reason, _):
            // Retry availability is shown via the controls section.
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "obsidian.status.interrupted"),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(reason)

        case .blocked(let reason):
            // Requirement 8: blocked MUST be visually distinct from idle.
            // Uses red color and an explicit label to prevent any idle-state
            // misreading.
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "obsidian.status.blocked"),
                    systemImage: "xmark.circle"
                )
                .foregroundStyle(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "obsidian.status.blocked.a11y"))
            .accessibilityValue(reason)

        case .failed(let reason, _):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "obsidian.status.failed"),
                    systemImage: "exclamationmark.octagon"
                )
                .foregroundStyle(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(reason)
        }
    }

    // MARK: - Controls section

    @ViewBuilder
    private var controlsSection: some View {
        HStack(spacing: 12) {
            Button(String(localized: "obsidian.action.enable")) {
                Task { await model.enableSync() }
            }
            .accessibilityLabel(String(localized: "obsidian.action.enable.a11y"))
            .disabled(model.isOperationInFlight)

            Button(String(localized: "obsidian.action.disable")) {
                Task { await model.disableSync() }
            }
            .accessibilityLabel(String(localized: "obsidian.action.disable.a11y"))
            .disabled(model.isOperationInFlight)

            // Requirement 6: retry offered ONLY for retryable conditions.
            if model.isRetryAvailable {
                Button(String(localized: "obsidian.action.retry")) {
                    Task { await model.retrySync() }
                }
                .accessibilityLabel(String(localized: "obsidian.action.retry.a11y"))
                .accessibilityHint(String(localized: "obsidian.action.retry.hint"))
                .disabled(model.isOperationInFlight)
            }
        }

        // FIX 1: Enable outcome non-success surfacing.
        // A daemon-refused Enable (e.g. authorization missing, policy violation)
        // currently shows NOTHING — the user cannot distinguish a refused enable
        // from a no-op. .enabled causes a status reload that makes success visible;
        // only .refused and .failed need inline feedback here.
        if let outcome = model.lastEnableOutcome {
            switch outcome {
            case .enabled:
                EmptyView()  // Status section already reflects the new .starting state.
            case .refused(let reason):
                Label(
                    String(localized: "obsidian.outcome.enable.refused \(reason)"),
                    systemImage: "hand.raised"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel(
                    String(localized: "obsidian.outcome.enable.refused.a11y \(reason)")
                )
                .accessibilityValue(reason)
            case .failed(let reason):
                Text(String(localized: "obsidian.outcome.enable.failed \(reason)"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityValue(reason)
            }
        }

        // FIX 1: Retry outcome non-success surfacing.
        // A refused or failed retry currently looks like the button did nothing.
        // .restarted causes a status reload that makes success visible in the
        // status section; only .refused and .failed need inline feedback.
        if let outcome = model.lastRetryOutcome {
            switch outcome {
            case .restarted:
                EmptyView()  // Status section shows new state after successful retry.
            case .refused(let reason):
                Label(
                    String(localized: "obsidian.outcome.retry.refused \(reason)"),
                    systemImage: "hand.raised"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel(
                    String(localized: "obsidian.outcome.retry.refused.a11y \(reason)")
                )
                .accessibilityValue(reason)
            case .failed(let reason):
                Text(String(localized: "obsidian.outcome.retry.failed \(reason)"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityValue(reason)
            }
        }

        // Disablement report — requirement 7: surface only what the daemon
        // reported. Never synthesize a "data removed" message from the status
        // transition alone.
        if let report = model.lastDisablementReport {
            switch report {
            case .disabledOnly:
                Text(String(localized: "obsidian.report.disabled.only"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .disabledAndRemoved:
                Text(String(localized: "obsidian.report.disabled.and.removed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
#endif
