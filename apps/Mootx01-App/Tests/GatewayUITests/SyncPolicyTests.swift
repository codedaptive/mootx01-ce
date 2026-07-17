import Testing
import Foundation
import MootGateway

// SyncPolicy persistence tests (CVK-WB2).
//
// Tests the UserDefaults-backed SyncPolicy type that persists the user's
// iCloud sync preference. Pattern mirrors MenuBarPolicyTests (M-MXA-7).

@Suite("SyncPolicy — defaults and persistence (CVK-WB2)")
struct SyncPolicyTests {

    @Test("default is false when the key is absent (first run)")
    func defaultIsFalseWhenKeyAbsent() throws {
        let d = try #require(UserDefaults(suiteName: "cvk-wb2-sync-policy"))
        d.removePersistentDomain(forName: "cvk-wb2-sync-policy")
        // Absent key → false, matching MootSyncDriver's .disabled default.
        #expect(SyncPolicy.isEnabled(defaults: d) == false)
        d.removePersistentDomain(forName: "cvk-wb2-sync-policy")
    }

    @Test("round-trips stored value (enabled → disabled → enabled)")
    func roundTripsStoredValue() throws {
        let d = try #require(UserDefaults(suiteName: "cvk-wb2-sync-policy"))
        d.removePersistentDomain(forName: "cvk-wb2-sync-policy")

        d.set(true, forKey: SyncPolicy.defaultsKey)
        #expect(SyncPolicy.isEnabled(defaults: d) == true)

        d.set(false, forKey: SyncPolicy.defaultsKey)
        #expect(SyncPolicy.isEnabled(defaults: d) == false)

        d.set(true, forKey: SyncPolicy.defaultsKey)
        #expect(SyncPolicy.isEnabled(defaults: d) == true)

        d.removePersistentDomain(forName: "cvk-wb2-sync-policy")
    }

    @Test("config(enabled: false) returns SyncConfig.disabled")
    func configFalseReturnsDisabled() {
        let config = SyncPolicy.config(enabled: false)
        #expect(config.enabled == false)
    }

    @Test("config(enabled: true) returns an enabled SyncConfig")
    func configTrueReturnsEnabled() {
        let config = SyncPolicy.config(enabled: true)
        #expect(config.enabled == true)
    }
}
