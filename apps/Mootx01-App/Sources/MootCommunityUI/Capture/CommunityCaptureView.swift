import SwiftUI

public struct CommunityCaptureView: View {
    @Bindable private var model: CommunityCaptureModel
    private let compact: Bool

    public init(model: CommunityCaptureModel, compact: Bool = false) {
        self.model = model
        self.compact = compact
    }

    public var body: some View {
        Form {
            Section(String(localized: compact ? "Quick Capture" : "Capture")) {
                TextField(String(localized: "Subject"), text: $model.subject)
                TextEditor(text: $model.body)
                    .frame(minHeight: compact ? 90 : 180)
                    .accessibilityLabel(String(localized: "Capture content"))
            }

            if let choices = model.choices {
                if model.policyNeedsReview {
                    Section(String(localized: "Capture policy changed")) {
                        Text(String(localized: "The resident daemon changed the available placement or sensitivity choices. Review the complete policy before capturing."))
                            .accessibilityLabel(String(localized: "Capture policy requires review"))
                    }
                }
                Section(String(localized: "Placement")) {
                    Picker(String(localized: "Destination"), selection: $model.selectedDestinationID) {
                        ForEach(choices.destinations) { destination in
                            Text(destination.title).tag(Optional(destination.id))
                        }
                    }
                    .accessibilityIdentifier("community.capture.destination")
                    .accessibilityValue(model.selectedDestinationAccessibilityValue)
                    .accessibilityHint(model.selectedDestinationAccessibilityHint)
                    if let destination = model.selectedDestination {
                        Text(destination.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section(String(localized: "Privacy")) {
                    Picker(String(localized: "Sensitivity"), selection: $model.sensitivity) {
                        ForEach(choices.sensitivities) { sensitivity in
                            Text(sensitivity.rawValue.capitalized).tag(sensitivity)
                        }
                    }
                    .accessibilityIdentifier("community.capture.sensitivity")
                    .accessibilityValue(model.sensitivityAccessibilityValue)
                    .accessibilityHint(model.sensitivityAccessibilityHint)
                    Toggle(String(localized: "Eligible for export"), isOn: $model.exportEligible)
                        .accessibilityIdentifier("community.capture.export-eligibility")
                        .accessibilityHint(String(localized: "Allows approved export workflows to include this capture."))
                    Toggle(String(localized: "Eligible for LAN sharing"), isOn: $model.lanEligible)
                        .accessibilityIdentifier("community.capture.lan-eligibility")
                        .accessibilityHint(String(localized: "Allows the resident daemon to serve this capture when LAN sharing is active."))
                }

                Button(model.isSubmitting ? String(localized: "Capturing…") : String(localized: "Capture")) {
                    Task { await model.submit() }
                }
                .disabled(!model.canSubmit)
            } else if model.isLoading {
                ProgressView(String(localized: "Loading capture policy…"))
            } else {
                ContentUnavailableView(
                    String(localized: "Capture unavailable"),
                    systemImage: "lock.trianglebadge.exclamationmark",
                    description: Text(String(localized: "The resident daemon has not supplied valid placement and privacy choices."))
                )
            }

            outcomeView
        }
        .formStyle(.grouped)
        .task { if model.choices == nil { await model.loadChoices() } }
    }

    @ViewBuilder
    private var outcomeView: some View {
        switch model.outcome {
        case .applied(let receipt):
            Section(String(localized: "Captured")) {
                Text(receipt.effectivePolicy.destination.title)
                Text(receipt.effectivePolicy.sensitivity.rawValue.capitalized)
                Text(receipt.effectivePolicy.exportEligible ? String(localized: "Export eligible") : String(localized: "Not export eligible"))
                Text(receipt.effectivePolicy.lanEligible ? String(localized: "LAN eligible") : String(localized: "Not LAN eligible"))
            }
        case .refused(let field, let reason):
            Section(String(localized: "Capture refused")) {
                Text(field.rawValue)
                Text(reason)
                Text(String(localized: "Your draft has been preserved."))
            }
        case .failed:
            Section(String(localized: "Capture failed")) {
                Text(String(localized: "The capture was not confirmed. Your draft has been preserved."))
            }
        case nil:
            EmptyView()
        }
    }
}
