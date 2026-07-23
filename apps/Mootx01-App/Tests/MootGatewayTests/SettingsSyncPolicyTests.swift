import Testing
import Foundation
import MootGateway

// SettingsSyncPolicyTests (FAB5-SM).
//
// Verifies the master-gate contract introduced by FAB5-SM:
//   1. masterEnabled defaults to false on a clean install.
//   2. migrateIfNeeded() migrates the WB2 key to masterEnabledKey exactly once.
//   3. isEnabled() reads masterEnabledKey (the authoritative gate) after migration.
//   4. The sync driver respects the gate — syncNow() returns false while disabled.
//
// .serialized: all four tests share a single UserDefaults suite to avoid races
// between removePersistentDomain and read/write pairs (same pattern as SyncPolicyTests).

@Suite("SyncPolicy master gate — FAB5-SM contract", .serialized)
struct SettingsSyncPolicyTests {

    private static let suite = "fab5-sm-master-gate"

    // MARK: - 1. Default off (clean install)

    @Test("masterEnabled is false on clean install — no CloudKit calls on first run")
    func masterEnabledDefaultsToFalse() throws {
        let d = try #require(UserDefaults(suiteName: Self.suite))
        d.removePersistentDomain(forName: Self.suite)
        defer { d.removePersistentDomain(forName: Self.suite) }

        // Fresh suite has neither key. isEnabled must return false.
        #expect(SyncPolicy.isEnabled(defaults: d) == false)
    }

    // MARK: - 2. Migration honored exactly once

    @Test("migrateIfNeeded copies WB2 key to master key — one-shot, then no-op")
    func migrationHonorsWB2KeyOnce() throws {
        let d = try #require(UserDefaults(suiteName: Self.suite))
        d.removePersistentDomain(forName: Self.suite)
        defer { d.removePersistentDomain(forName: Self.suite) }

        // Simulate a user who had WB2 sync enabled before upgrading.
        d.set(true, forKey: SyncPolicy.defaultsKey)
        #expect(d.object(forKey: SyncPolicy.masterEnabledKey) == nil)

        SyncPolicy.migrateIfNeeded(defaults: d)

        // Master key now carries the WB2 value.
        #expect(SyncPolicy.isEnabled(defaults: d) == true)
        // Legacy key was cleared.
        #expect(d.object(forKey: SyncPolicy.defaultsKey) == nil)

        // Second call is a no-op — master key already present.
        d.set(false, forKey: SyncPolicy.masterEnabledKey)
        SyncPolicy.migrateIfNeeded(defaults: d) // must not overwrite with legacy value
        // Legacy key is absent, so migrateIfNeeded has nothing to migrate; master key stays false.
        #expect(SyncPolicy.isEnabled(defaults: d) == false)
    }

    // MARK: - 3. isEnabled reads masterEnabledKey

    @Test("isEnabled reads masterEnabledKey after migration — round-trip")
    func isEnabledReadsMasterKey() throws {
        let d = try #require(UserDefaults(suiteName: Self.suite))
        d.removePersistentDomain(forName: Self.suite)
        defer { d.removePersistentDomain(forName: Self.suite) }

        // Write directly to master key (as @AppStorage in SettingsView would).
        d.set(true, forKey: SyncPolicy.masterEnabledKey)
        #expect(SyncPolicy.isEnabled(defaults: d) == true)

        d.set(false, forKey: SyncPolicy.masterEnabledKey)
        #expect(SyncPolicy.isEnabled(defaults: d) == false)
    }

    // MARK: - 4. Driver gate

    @Test("configure(.disabled) makes syncNow() return false — driver respects master gate")
    func driverRespectsGate() async {
        // Drive the shared driver into disabled state.
        await MootSyncDriver.shared.configure(SyncPolicy.config(enabled: false))
        let result = await MootSyncDriver.shared.syncNow()
        #expect(result == false)
    }
}
