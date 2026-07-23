import SwiftUI

// MARK: - AdvancedModeToggleView (FAB5-FR Part 2)
//
// Full-screen Settings tab for the Standard (consumer) profile.
// Exposes the Advanced Mode toggle so users can opt into the engineering tab set.
// Advanced mode persists via AppModel.isAdvancedMode (UserDefaults-backed).

struct AdvancedModeToggleView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                advancedModeSection
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "advancedmode.nav.title", defaultValue: "Settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    private var advancedModeSection: some View {
        Section {
            Toggle(isOn: $model.isAdvancedMode) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "advancedmode.toggle.label", defaultValue: "Advanced Mode"))
                        Text(
                            model.isAdvancedMode
                                ? String(localized: "advancedmode.toggle.subtitle.on",
                                         defaultValue: "All engineering tabs are visible.")
                                : String(localized: "advancedmode.toggle.subtitle.off",
                                         defaultValue: "Simplified view: Capture, Recall, and Intelligence.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(String(localized: "advancedmode.toggle.a11y.label", defaultValue: "Advanced Mode"))
            .accessibilityHint(String(localized: "advancedmode.toggle.a11y.hint",
                                      defaultValue: "When on, engineering tabs — The Top, Edges, Engine, and more — become visible."))
        } header: {
            Text(String(localized: "advancedmode.section.header", defaultValue: "Interface"))
        } footer: {
            Text(String(localized: "advancedmode.section.footer",
                        defaultValue: "Advanced Mode shows The Top, Apple Surfaces, Edges, Engine, Federation, and Miners. Designed for developers and power users."))
        }
    }
}
