import SwiftUI
import MootGateway

// MARK: - SettingsView (FAB5-SM, FAB5-ST)
//
// First-class Settings surface for the app. Entry point:
//   - macOS: system Settings window (Cmd+,) via `Settings { SettingsView() }` in Mootx01App.
//   - iOS/iPadOS: sheet from the gear toolbar button in EngineView.
//
// Design: one Sync section that owns the master iCloud sync switch. The master
// switch is the single authoritative gate — SyncTileView in EngineView mirrors
// the same UserDefaults value and reacts immediately. No second source of truth.
//
// FAB5-ST adds a Sensitive Tiers section with per-tier opt-in toggles (restricted,
// secret). Each requires device authentication (biometry or passcode) via
// TierAuthorizationStore before the keychain sentinel is written. Revoking drops
// the sentinel and emits WB1 retraction tombstones for now-above-ceiling rows.
// The secret tier toggle ships visible but disabled pending Perkins clearance
// (secretTierCleared build flag enables it).

public struct SettingsView: View {

    /// Master iCloud sync gate (FAB5-SM). Same key as SyncTileView — both
    /// views read and write UserDefaults["iCloudMasterEnabled"]; changes in
    /// one are immediately visible in the other.
    @AppStorage(SyncPolicy.masterEnabledKey) private var masterEnabled = false

    /// Restricted-tier sync authorization state (FAB5-ST). Loaded from
    /// TierAuthorizationStore on appear; updated optimistically on toggle,
    /// then snapped back if authentication fails.
    @State private var restrictedEnabled = false

#if secretTierCleared
    /// Secret-tier sync authorization state (FAB5-ST). Only compiled when
    /// secretTierCleared is set — the Perkins clearance build flag.
    @State private var secretEnabled = false
#endif

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
            sensitiveTierSection
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
            sensitiveTierSection
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
        }
    }

    // MARK: - Sensitive Tiers section (FAB5-ST)

    private var sensitiveTierSection: some View {
        Section {
            // Restricted tier toggle — auth-gated via TierAuthorizationStore.
            // Enabling triggers biometry/passcode; disabling revokes immediately (no auth).
            Toggle(isOn: $restrictedEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "settings.sync.tier.restricted.label",
                                   defaultValue: "Restricted Memories"))
                        Text(String(localized: "settings.sync.tier.restricted.detail",
                                   defaultValue: "Sync Restricted memories to your Apple devices."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                        .accessibilityHidden(true)
                }
            }
            .disabled(!masterEnabled)
            .accessibilityLabel(String(localized: "settings.sync.tier.restricted.a11y.label",
                                       defaultValue: "Restricted memory sync"))
            .accessibilityHint(String(localized: "settings.sync.tier.restricted.a11y.hint",
                                      defaultValue: "Requires device authentication to enable. Disabling revokes authorization and removes synced content from other devices."))
            .onChange(of: restrictedEnabled) { _, newValue in
                Task {
                    if newValue {
                        let granted = await TierAuthorizationStore.shared.authorize(.restricted)
                        if !granted {
                            // Auth failed or cancelled — snap back to off.
                            restrictedEnabled = false
                        } else {
                            await MootSyncDriver.shared.reconfigureForAuthorizedTiers()
                        }
                    } else {
                        // No auth required to revoke — user is reducing sync scope.
                        await MootSyncDriver.shared.revokeAndRetract(tier: .restricted)
                    }
                }
            }

#if secretTierCleared
            // Secret tier toggle — compiled only after Perkins clearance grants
            // the secretTierCleared build flag. Same auth flow as restricted.
            Toggle(isOn: $secretEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "settings.sync.tier.secret.label",
                                   defaultValue: "Secret Memories"))
                        Text(String(localized: "settings.sync.tier.secret.detail",
                                   defaultValue: "Sync Secret memories to your Apple devices."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .accessibilityHidden(true)
                }
            }
            .disabled(!masterEnabled)
            .accessibilityLabel(String(localized: "settings.sync.tier.secret.a11y.label",
                                       defaultValue: "Secret memory sync"))
            .accessibilityHint(String(localized: "settings.sync.tier.secret.a11y.hint",
                                      defaultValue: "Requires device authentication to enable. Disabling revokes authorization and removes synced content from other devices."))
            .onChange(of: secretEnabled) { _, newValue in
                Task {
                    if newValue {
                        let granted = await TierAuthorizationStore.shared.authorize(.secret)
                        if !granted {
                            secretEnabled = false
                        } else {
                            await MootSyncDriver.shared.reconfigureForAuthorizedTiers()
                        }
                    } else {
                        await MootSyncDriver.shared.revokeAndRetract(tier: .secret)
                    }
                }
            }
#else
            // Secret tier sync ships visible but disabled — pending Perkins security
            // clearance (FAB5-ST). The secretTierCleared build flag enables the live
            // toggle. The plumbing (TierAuthorizationStore, retraction stream) is
            // complete and tested; only this UI gate and the build flag are missing.
            Toggle(isOn: .constant(false)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "settings.sync.tier.secret.label",
                                   defaultValue: "Secret Memories"))
                        Text(String(localized: "settings.sync.tier.secret.unavailable",
                                   defaultValue: "Not available in this build."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .accessibilityHidden(true)
                }
            }
            .disabled(true)
            .accessibilityLabel(String(localized: "settings.sync.tier.secret.a11y.label",
                                       defaultValue: "Secret memory sync"))
            .accessibilityHint(String(localized: "settings.sync.tier.secret.a11y.unavailable.hint",
                                      defaultValue: "Not available in this build."))
#endif
        } header: {
            Text(String(localized: "settings.sync.sensitivetier.header",
                       defaultValue: "Sensitive Tiers"))
        } footer: {
#if secretTierCleared
            Text(String(localized: "settings.sync.sensitivetier.footer",
                       defaultValue: "Each tier requires device authentication to enable. Disabling removes synced content from other devices."))
#else
            Text(String(localized: "settings.sync.sensitivetier.footer",
                       defaultValue: "Restricted sync requires device authentication. Secret sync is pending clearance and will be enabled in a future update."))
#endif
        }
        .task {
            // Load current authorization state from TierAuthorizationStore.
            // Runs on section appear — safe to call async without a spinner because
            // the keychain read is synchronous under the hood (actor serializes it).
            restrictedEnabled = await TierAuthorizationStore.shared.isAuthorized(.restricted)
#if secretTierCleared
            secretEnabled = await TierAuthorizationStore.shared.isAuthorized(.secret)
#endif
        }
    }
}
