import SwiftUI
import MootGateway

// MARK: - SettingsView (FAB5-SM, FAB5-ST, FAB5-J1)
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
//
// FAB5-J1 adds a Continuous Vault section (off by default). It stores:
//   vaultResidentEnabled  — UserDefaults Bool (master toggle)
//   vaultResidentPath     — UserDefaults String (vault root directory path)
// The daemon reads MOOTX01_VAULT_PATH (env var); the launchd installer bridge
// that translates UserDefaults→env var is a follow-on (out of FAB5-J1 scope).

public struct SettingsView: View {

    /// Master iCloud sync gate (FAB5-SM). Same key as SyncTileView — both
    /// views read and write UserDefaults["iCloudMasterEnabled"]; changes in
    /// one are immediately visible in the other.
    @AppStorage(SyncPolicy.masterEnabledKey) private var masterEnabled = false

    /// Restricted-tier sync authorization state (FAB5-ST). Loaded from
    /// TierAuthorizationStore on appear; updated optimistically on toggle,
    /// then snapped back if authentication fails.
    @State private var restrictedEnabled = false

    /// Continuous vault sync master toggle (FAB5-J1). Off by default.
    /// Stored in UserDefaults["vaultResidentEnabled"]. When on, the daemon
    /// (MOOTX01_VAULT_PATH) syncs public memories with the vault continuously.
    @AppStorage("vaultResidentEnabled") private var vaultResidentEnabled = false

    /// Obsidian vault root directory path (FAB5-J1).
    /// Stored in UserDefaults["vaultResidentPath"]. Passed to MOOTX01_VAULT_PATH
    /// by the launchd installer bridge (follow-on, not in FAB5-J1 scope).
    @AppStorage("vaultResidentPath") private var vaultResidentPath = ""

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
            continuousVaultSection
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
            continuousVaultSection
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

    // MARK: - Continuous Vault section (FAB5-J1)

    // UserDefaults keys: vaultResidentEnabled (Bool), vaultResidentPath (String).
    // Daemon reads MOOTX01_VAULT_PATH; launchd bridge is follow-on (FAB5-J1 INTENTIONALLY_LEFT).
    private var continuousVaultSection: some View {
        Section {
            Toggle(isOn: $vaultResidentEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "settings.vault.toggle.label",
                                   defaultValue: "Obsidian Vault Sync"))
                        Text(vaultResidentEnabled
                             ? String(localized: "settings.vault.status.on",
                                      defaultValue: "Public memories sync continuously with your vault.")
                             : String(localized: "settings.vault.status.off",
                                      defaultValue: "Export your Public memories to an Obsidian vault."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(String(localized: "settings.vault.toggle.a11y.label",
                                       defaultValue: "Obsidian Vault Sync"))
            .accessibilityHint(String(localized: "settings.vault.toggle.a11y.hint",
                                      defaultValue: "When on, memories marked as Public are continuously synced to and from your Obsidian vault. Private, Restricted, and Secret memories are never exported."))

            if vaultResidentEnabled {
                TextField(
                    String(localized: "settings.vault.path.placeholder",
                           defaultValue: "Vault path (e.g. /Users/you/Vault)"),
                    text: $vaultResidentPath
                )
                .font(.caption.monospaced())
                .autocorrectionDisabled()
                .accessibilityLabel(String(localized: "settings.vault.path.a11y.label",
                                           defaultValue: "Vault directory path"))
                .accessibilityHint(String(localized: "settings.vault.path.a11y.hint",
                                          defaultValue: "Enter the full path to your Obsidian vault folder."))
            }
        } header: {
            Text(String(localized: "settings.vault.section.header",
                       defaultValue: "Obsidian Vault"))
        } footer: {
            Text(String(localized: "settings.vault.section.footer",
                       defaultValue: "Only memories you mark as Public sync to the vault. Private, Elevated, Restricted, and Secret memories are never exported, regardless of this setting."))
        }
    }
}
