import SwiftUI

// MARK: - LANControlView  (APP-07 — Portable LAN Controls)
//
// macOS-only SwiftUI surface for APP-07.
// Renders daemon-confirmed state through an injected LANControlModel.
// No business logic lives here — the model is the sole transformation layer.
//
// CRITICAL: no import of MootGateway, CommunityAppModel, or any LAN server
// runtime. This view observes the injected model only.
//
// Accessibility: every interactive control carries an accessibility label and
// consequence hint. Blocked/failed states carry an accessibility value with
// the humanized daemon reason (CommunityDaemonReason); the machine code is
// rendered only as a labeled, selectable technical caption (census R-C22).
// String(localized:) for all display strings.
//
// Requirement 5: ineligible count is rendered in a separate row labeled
// "excluded" — it is never added to the eligible count row.
// Requirement 7: stop button does not optimistically label itself "stopped";
// the status section reflects the confirmed stop from the model.
// Requirement 8: no control in this view bypasses the model — all mutations
// flow through the model's async methods which enforce the fail-closed contract.

#if os(macOS)
@MainActor
public struct LANControlView: View {

    @Bindable var model: LANControlModel

    public init(model: LANControlModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            policySection
            statusSection
            controlsSection
        }
        .padding()
        .task {
            await model.loadServingStatus()
            await model.loadServingPolicy()
        }
    }

    // MARK: - Policy section (requirement 2, requirement 5)

    @ViewBuilder
    private var policySection: some View {
        GroupBox(label: Text(String(localized: "lan.section.policy"))) {
            if let policy = model.servingPolicy {
                VStack(alignment: .leading, spacing: 4) {
                    // Requirement 2: show eligible count.
                    Text(String(localized: "lan.policy.eligible \(policy.eligibleCount)"))
                        .accessibilityLabel(
                            String(localized: "lan.policy.eligible.a11y \(policy.eligibleCount)")
                        )
                    // Requirement 5: ineligible count rendered as excluded,
                    // in a separate row — never merged with the eligible row.
                    if policy.ineligibleCount > 0 {
                        Text(
                            String(
                                localized:
                                    "lan.policy.excluded \(policy.ineligibleCount)"
                            )
                        )
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            String(
                                localized:
                                    "lan.policy.excluded.a11y \(policy.ineligibleCount)"
                            )
                        )
                    }
                    Text(policy.policyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    policyLoadFailure
                }
            } else if model.isLoadingPolicy || model.lastPolicyLoadOutcome == nil {
                ProgressView()
                    .accessibilityLabel(String(localized: "lan.policy.loading.a11y"))
            } else {
                policyLoadFailure
            }
        }
    }

    @ViewBuilder
    private var policyLoadFailure: some View {
        if let outcome = model.lastPolicyLoadOutcome {
            switch outcome {
            case .loaded:
                EmptyView()
            case .blocked(let reasonCode):
                let presented = CommunityDaemonReason(code: reasonCode)
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        String(localized: "lan.policy.blocked \(presented.explanation)"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    reasonCodeDetail(presented)
                }
                .accessibilityValue(presented.explanation)
            case .failed(let reasonCode):
                let presented = CommunityDaemonReason(code: reasonCode)
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        String(localized: "lan.policy.failed \(presented.explanation)"),
                        systemImage: "exclamationmark.octagon"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    reasonCodeDetail(presented)
                }
                .accessibilityValue(presented.explanation)
            }
        }
    }

    // MARK: - Status section (requirement 4: six distinct states)

    @ViewBuilder
    private var statusSection: some View {
        GroupBox(label: Text(String(localized: "lan.section.status"))) {
            if model.isLoadingStatus {
                ProgressView()
                    .accessibilityLabel(String(localized: "lan.status.loading.a11y"))
            } else {
                servingStatusContent(model.servingStatus)
            }
        }
    }

    @ViewBuilder
    private func servingStatusContent(_ status: LANServingStatus) -> some View {
        switch status {
        case .stopped:
            // Requirement 1: default-off state is clearly labeled.
            Label(
                String(localized: "lan.status.stopped"),
                systemImage: "wifi.slash"
            )
            .foregroundStyle(.secondary)

        case .starting:
            ProgressView(String(localized: "lan.status.starting"))

        case .active(let endpoint, let authState):
            // Requirement 3: surface the daemon-confirmed endpoint and auth state.
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "lan.status.active"),
                    systemImage: "wifi"
                )
                Text(endpoint)
                    .font(.caption.monospaced())
                    .accessibilityLabel(String(localized: "lan.status.endpoint.a11y"))
                    .accessibilityValue(endpoint)
                // Requirement 8: auth state surfaced verbatim — expired is not hidden.
                switch authState {
                case .valid:
                    Text(String(localized: "lan.auth.valid"))
                        .font(.caption)
                        .foregroundStyle(.green)
                case .expired:
                    Text(String(localized: "lan.auth.expired"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .notObtained:
                    Text(String(localized: "lan.auth.not.obtained"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

        case .interrupted(let reasonCode):
            let presented = CommunityDaemonReason(code: reasonCode)
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "lan.status.interrupted"),
                    systemImage: "wifi.slash"
                )
                .foregroundStyle(.orange)
                Text(presented.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                reasonCodeDetail(presented)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(presented.explanation)

        case .blocked(let reasonCode):
            // Blocked is structurally distinct from stopped — rendered in red
            // with an explicit blocked label so it cannot be read as idle.
            let presented = CommunityDaemonReason(code: reasonCode)
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "lan.status.blocked"),
                    systemImage: "xmark.circle"
                )
                .foregroundStyle(.red)
                Text(presented.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                reasonCodeDetail(presented)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "lan.status.blocked.a11y"))
            .accessibilityValue(presented.explanation)

        case .failed(let reasonCode):
            let presented = CommunityDaemonReason(code: reasonCode)
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(localized: "lan.status.failed"),
                    systemImage: "exclamationmark.octagon"
                )
                .foregroundStyle(.red)
                Text(presented.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                reasonCodeDetail(presented)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(presented.explanation)
        }
    }

    /// Labeled technical detail ("Reason code: …") rendered under a human
    /// explanation. Selectable so a support request can carry the daemon's
    /// exact word; the code itself is never the primary display language.
    private func reasonCodeDetail(_ presented: CommunityDaemonReason) -> some View {
        Text(presented.technicalDetail)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    // MARK: - Controls section

    @ViewBuilder
    private var controlsSection: some View {
        HStack(spacing: 12) {
            // Start — requirement 8: all policy enforcement is the daemon's job.
            // This button submits a request; the model accepts or surfaces denial.
            Button(String(localized: "lan.action.start")) {
                Task { await model.startServing() }
            }
            .accessibilityLabel(String(localized: "lan.action.start.a11y"))
            .accessibilityHint(String(localized: "lan.action.start.hint"))
            .disabled(model.isOperationInFlight)

            // Stop — requirement 7: label says "stop", not "stopped", because
            // the button submits a request; the status section reflects confirmation.
            Button(String(localized: "lan.action.stop")) {
                Task { await model.stopServing() }
            }
            .accessibilityLabel(String(localized: "lan.action.stop.a11y"))
            .accessibilityHint(String(localized: "lan.action.stop.hint"))
            .disabled(model.isOperationInFlight)

            // Eligibility refresh — requirement 6.
            Button(String(localized: "lan.action.refresh.eligibility")) {
                Task { await model.refreshEligibility() }
            }
            .accessibilityLabel(
                String(localized: "lan.action.refresh.eligibility.a11y")
            )
            .disabled(model.isOperationInFlight)
        }

        // Start outcome surfacing. Active state is shown in the status section;
        // only non-success outcomes need inline feedback here.
        if let outcome = model.lastStartOutcome {
            switch outcome {
            case .started:
                EmptyView()  // Status section already shows .active.
            case .denied(let reasonCode):
                let presented = CommunityDaemonReason(code: reasonCode)
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        String(localized: "lan.outcome.denied \(presented.explanation)"),
                        systemImage: "hand.raised"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    reasonCodeDetail(presented)
                }
            case .failed(let reasonCode):
                let presented = CommunityDaemonReason(code: reasonCode)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "lan.outcome.failed \(presented.explanation)"))
                        .font(.caption)
                        .foregroundStyle(.red)
                    reasonCodeDetail(presented)
                }
            }
        }

        // Stop outcome failure surfacing. Confirmed stops are shown via
        // the status section; only failure feedback is shown inline.
        if let outcome = model.lastStopOutcome, case .failed(let reasonCode) = outcome {
            let presented = CommunityDaemonReason(code: reasonCode)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "lan.outcome.stop.failed \(presented.explanation)"))
                    .font(.caption)
                    .foregroundStyle(.red)
                reasonCodeDetail(presented)
            }
        }

        // FIX 4: Eligibility refresh outcome surfacing.
        // A refused or failed eligibility refresh currently shows unchanged counts
        // with no indication — the user cannot tell whether the refresh did anything.
        // .updated is handled by the policy section (counts change visibly there);
        // only non-success cases require inline feedback.
        if let outcome = model.lastEligibilityOutcome {
            switch outcome {
            case .updated:
                EmptyView()  // Policy section already shows updated counts.
            case .refused(let reasonCode):
                let presented = CommunityDaemonReason(code: reasonCode)
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        String(localized: "lan.outcome.eligibility.refused \(presented.explanation)"),
                        systemImage: "hand.raised"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(
                        String(localized: "lan.outcome.eligibility.refused.a11y \(presented.explanation)")
                    )
                    .accessibilityValue(presented.explanation)
                    reasonCodeDetail(presented)
                }
            case .failed(let reasonCode):
                let presented = CommunityDaemonReason(code: reasonCode)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "lan.outcome.eligibility.failed \(presented.explanation)"))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityValue(presented.explanation)
                    reasonCodeDetail(presented)
                }
            }
        }
    }
}
#endif
