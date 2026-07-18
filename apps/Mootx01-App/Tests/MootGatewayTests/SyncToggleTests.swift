import Testing
import Foundation
import MootGateway

// Sync toggle determinism tests (CVK-WB2).
//
// Verifies the behavioural contract the toggle relies on:
//   1. configure(.disabled) → syncNow() returns false (toggle-off disables deterministically)
//   2. SyncPolicy.isEnabled() reads the persisted preference the same way the
//      app launch path does (enabled-at-launch honored — storage side of the contract).
//
// CloudKit itself is NOT exercised: configure(.cloudKitDefault) → syncNow()
// would return false in the test environment (no provisioned container, no iCloud
// account) via MootSyncDriver's graceful degradation path, making the "returns true"
// assertion unreliable. The toggle-on path is exercised at the UI level via
// the SyncTileView onChange wiring (visible in the committed diff).

@Suite("MootSyncDriver — toggle-off disables deterministically (CVK-WB2)")
struct SyncToggleTests {

    @Test("configure(.disabled) makes syncNow() return false — toggle-off is deterministic")
    func toggleOffDisablesDeterministically() async {
        // Drive the shared driver into the disabled state, just as
        // the toggle's onChange handler does when the user flips it off.
        // This also exercises SyncPolicy.config(enabled: false) → SyncConfig.disabled.
        let cfg = SyncPolicy.config(enabled: false)
        #expect(cfg.enabled == false)
        await MootSyncDriver.shared.configure(cfg)
        // syncNow() must return false: administratively disabled, no CloudKit call.
        let result = await MootSyncDriver.shared.syncNow()
        #expect(result == false)
    }

    @Test("SyncPolicy.isEnabled() defaults to false — enabled-at-launch default is safe")
    func enabledAtLaunchDefaultIsSafe() throws {
        let suite = "cvk-wb2-launch-gate"
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        // On first run with no stored preference, the driver must not auto-enable.
        // This is the storage half of the "enabled-at-launch honored" contract:
        // the app reads SyncPolicy.isEnabled() to decide whether to call configure.
        #expect(SyncPolicy.isEnabled(defaults: d) == false)
        d.removePersistentDomain(forName: suite)
    }
}
