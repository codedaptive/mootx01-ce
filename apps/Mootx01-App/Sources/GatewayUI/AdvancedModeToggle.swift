import SwiftUI
import MootGateway

// MARK: - AdvancedModeToggleView (FAB5-FR Part 2)
//
// Full-screen Settings tab for both Standard and Advanced profiles.
// Shows the iCloud Sync section (same key as SettingsView — single source of
// truth; changes in either view are immediately visible in both) and the
// Advanced Mode toggle. Standard users reach iCloud Sync here; Advanced users
// also see it in the Engine tab's SyncTileView.

struct AdvancedModeToggleView: View {
    @Bindable var model: AppModel

    // Same UserDefaults key as SettingsView and SyncTileView (SyncPolicy.masterEnabledKey).
    // All three views share the key — changes in any are immediately reflected in the others.
    @AppStorage(SyncPolicy.masterEnabledKey) private var masterEnabled = false

    var body: some View {
        NavigationStack {
            Form {
                syncSection
                advancedModeSection
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "advancedmode.nav.title", defaultValue: "Settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    // MARK: iCloud Sync section
    // Mirrors SettingsView.syncSection — same key, same driver call, same copy.
    // Duplicated here so Standard-profile users (who never see SettingsView on
    // iOS, since the gear button is on the Engine tab that moves behind Advanced)
    // can still reach the sync master switch.

    private var syncSection: some View {
        Section {
            Toggle(isOn: $masterEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "settings.sync.toggle.label",
                                   defaultValue: "iCloud Sync"))
                        Text(masterEnabled
                             ? String(localized: "settings.sync.status.on",
                                      defaultValue: "Normal and Elevated memories sync across your Apple devices.")
                             : String(localized: "settings.sync.status.off",
                                      defaultValue: "Memories stay on this device."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "icloud")
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(String(localized: "settings.sync.toggle.a11y.label",
                                       defaultValue: "iCloud Sync"))
            .accessibilityHint(String(localized: "settings.sync.toggle.a11y.hint",
                                      defaultValue: "When on, Normal and Elevated memories sync across your Apple devices via iCloud."))
            .onChange(of: masterEnabled) { _, newValue in
                Task {
                    await MootSyncDriver.shared.configure(SyncPolicy.config(enabled: newValue))
                    if newValue {
                        _ = await MootSyncDriver.shared.syncNow()
                    }
                }
            }
        } header: {
            Text(String(localized: "settings.sync.section.header",
                       defaultValue: "iCloud Sync"))
        } footer: {
            Text(String(localized: "settings.sync.section.footer",
                        defaultValue: "Restricted and Secret memories never leave this device, regardless of this setting."))
        }
    }

    // MARK: Advanced Mode section

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
                                         defaultValue: "Simplified view: Capture, Recall, Intelligence, and Settings.")
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
