import SwiftUI
import MootGateway

// MARK: - SettingsView (FAB5-SM)
//
// First-class Settings surface for the app. Entry point:
//   - macOS: system Settings window (Cmd+,) via `Settings { SettingsView() }` in Mootx01App.
//   - iOS/iPadOS: sheet from the gear toolbar button in EngineView.
//
// Design: one Sync section that owns the master iCloud sync switch. The master
// switch is the single authoritative gate — SyncTileView in EngineView mirrors
// the same UserDefaults value and reacts immediately. No second source of truth.
//
// The placeholder "Sensitive Tiers" section header is reserved for mission st,
// which will populate it with per-tier sync policy controls.

public struct SettingsView: View {

    /// Master iCloud sync gate (FAB5-SM). Same key as SyncTileView — both
    /// views read and write UserDefaults["iCloudMasterEnabled"]; changes in
    /// one are immediately visible in the other.
    @AppStorage(SyncPolicy.masterEnabledKey) private var masterEnabled = false

    public init() {}

    public var body: some View {
        #if os(macOS)
        macOSContent
        #else
        NavigationStack {
            iosContent
                .navigationTitle(String(localized: "settings.nav.title", defaultValue: "Settings"))
                .navigationBarTitleDisplayMode(.inline)
        }
        #endif
    }

    // MARK: - macOS layout

    #if os(macOS)
    private var macOSContent: some View {
        Form {
            syncSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, idealWidth: 480)
        .padding()
    }
    #endif

    // MARK: - iOS layout

    private var iosContent: some View {
        Form {
            syncSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Sync section

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
                    // Same driver wiring as SyncTileView: configure() is idempotent
                    // when re-applied with the same value; toggling off tears down
                    // the active engine; toggling on fires an immediate sync beat.
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
                .font(.caption)
        }

        // Placeholder for mission st — per-tier sync policy controls.
        // This section header is intentionally empty until st populates it.
    }
}
