#if os(macOS)
import Testing
import Foundation
@testable import GatewayUI

// M-MXA-7 — termination + insertion policy (the testable core of menu-bar
// headless mode; the MenuBarExtra scene itself is app-target UI).

@Suite("MenuBarPolicy (M-MXA-7)")
struct MenuBarPolicyTests {

    @Test("menu-bar mode ON keeps the app alive after the last window closes")
    func menuBarModeSurvivesLastWindow() {
        #expect(MenuBarPolicy.shouldTerminateAfterLastWindowClosed(menuBarModeEnabled: true) == false)
    }

    @Test("menu-bar mode OFF preserves quit-on-last-window-close")
    func windowModeQuitsOnLastWindow() {
        #expect(MenuBarPolicy.shouldTerminateAfterLastWindowClosed(menuBarModeEnabled: false) == true)
    }

    @Test("setting defaults ON when unset; reads stored value when set")
    func settingDefaultsOnAndRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "mxa7-policy-tests"))
        defaults.removePersistentDomain(forName: "mxa7-policy-tests")
        #expect(MenuBarPolicy.isEnabled(defaults: defaults) == true)

        defaults.set(false, forKey: MenuBarPolicy.defaultsKey)
        #expect(MenuBarPolicy.isEnabled(defaults: defaults) == false)

        defaults.set(true, forKey: MenuBarPolicy.defaultsKey)
        #expect(MenuBarPolicy.isEnabled(defaults: defaults) == true)
        defaults.removePersistentDomain(forName: "mxa7-policy-tests")
    }
}
#endif

// M-ING-2 — miner source configuration persistence.
@Suite("MinerSourceConfig (M-ING-2)")
struct MinerSourceConfigTests {
    @Test("defaults: disabled, Personal Life wing, per-source room, daily")
    func shippedDefaults() throws {
        let d = try #require(UserDefaults(suiteName: "ming2-config-tests"))
        d.removePersistentDomain(forName: "ming2-config-tests")
        let c = MinerSourceConfig.load(sourceID: "calendar", room: "calendar", defaults: d)
        #expect(c.enabled == false)
        #expect(c.wing == "Personal Life")
        #expect(c.room == "calendar")
        #expect(c.cadence == .daily)
    }

    @Test("save/load round-trips every field")
    func roundTrip() throws {
        let d = try #require(UserDefaults(suiteName: "ming2-config-tests"))
        d.removePersistentDomain(forName: "ming2-config-tests")
        var c = MinerSourceConfig.load(sourceID: "birthdays", room: "birthdays", defaults: d)
        c.enabled = true
        c.wing = "Family"
        c.room = "people"
        c.cadence = .weekly
        c.save(defaults: d)
        let back = MinerSourceConfig.load(sourceID: "birthdays", room: "x", defaults: d)
        #expect(back == c)
        d.removePersistentDomain(forName: "ming2-config-tests")
    }
}
