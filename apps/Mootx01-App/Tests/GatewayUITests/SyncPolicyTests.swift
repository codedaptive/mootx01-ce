import Testing
import Foundation
import MootGateway

// SyncPolicy persistence tests (CVK-WB2, updated FAB5-SM).
//
// Tests the UserDefaults-backed SyncPolicy type. FAB5-SM updated isEnabled()
// to read from masterEnabledKey ("iCloudMasterEnabled") instead of the legacy
// defaultsKey ("iCloudSyncEnabled"). Round-trip tests updated accordingly.

// .serialized: both tests share the "cvk-wb2-sync-policy" UserDefaults
// suite; parallel execution let one test's removePersistentDomain fire
// between another's set/read pair (Adams Wave B CRITICAL #1).
@Suite("SyncPolicy — defaults and persistence (CVK-WB2)", .serialized)
struct SyncPolicyTests {

    @Test("default is false when the key is absent (first run)")
    func defaultIsFalseWhenKeyAbsent() throws {
        let d = try #require(UserDefaults(suiteName: "cvk-wb2-sync-policy"))
        d.removePersistentDomain(forName: "cvk-wb2-sync-policy")
        // Absent masterEnabledKey → false, matching MootSyncDriver's .disabled default.
        #expect(SyncPolicy.isEnabled(defaults: d) == false)
        d.removePersistentDomain(forName: "cvk-wb2-sync-policy")
    }

    @Test("round-trips stored value via masterEnabledKey (enabled → disabled → enabled)")
    func roundTripsStoredValue() throws {
        let d = try #require(UserDefaults(suiteName: "cvk-wb2-sync-policy"))
        d.removePersistentDomain(forName: "cvk-wb2-sync-policy")

        // FAB5-SM: isEnabled() reads masterEnabledKey, not defaultsKey.
        d.set(true, forKey: SyncPolicy.masterEnabledKey)
        #expect(SyncPolicy.isEnabled(defaults: d) == true)

        d.set(false, forKey: SyncPolicy.masterEnabledKey)
        #expect(SyncPolicy.isEnabled(defaults: d) == false)

        d.set(true, forKey: SyncPolicy.masterEnabledKey)
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
