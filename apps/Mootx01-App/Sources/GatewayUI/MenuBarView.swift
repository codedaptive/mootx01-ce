#if os(macOS)
import SwiftUI
import AppKit
import MootGateway

// MARK: - Menu-bar headless mode  (M-MXA-7)
//
// macOS is the mining executor (Bob ruling D9, estate 9B1F355E): the APP —
// not a daemon — persists in the menu bar with the embedded engine alive, so
// miners and intents keep working with no window open. MOOTx01-App never
// spawns the mootx01 CLI; the two are separate programs.
//
// Dock policy (documented decision): the app keeps its regular Dock presence
// even when only the menu-bar item is left. Switching to .accessory when
// windowless makes reopening from Dock/Cmd-Tab surprising; v1 favors
// predictability. Revisit only on user feedback.

/// Termination + insertion policy for menu-bar mode. Pure functions in the
/// package (not the app target) so the policy is unit-testable.
public enum MenuBarPolicy {
    /// UserDefaults key for the user setting. Default ON: headless mining is
    /// the reason the mode exists (D9).
    public static let defaultsKey = "menuBarModeEnabled"

    /// AppKit asks this when the last window closes: quit unless menu-bar
    /// mode keeps the app alive. Quit from the menu-bar menu always works.
    public static func shouldTerminateAfterLastWindowClosed(menuBarModeEnabled: Bool) -> Bool {
        !menuBarModeEnabled
    }

    /// Reads the current setting; unset means ON.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// Content of the MenuBarExtra: estate status, open, quit. "Mine Now" joins
/// when M-ING-2 Part 2 lands its concrete miners.
public struct MenuBarView: View {
    @Bindable private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var miningSource: String?
    @State private var miningStatus: String?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        // Estate status straight from the live model (same line the Engine
        // tab shows), so the headless app is never a black box.
        Text(model.statusLine)

        Divider()

        Button {
            Task { await mineNow("calendar") }
        } label: {
            Label("Mine Calendar Now", systemImage: "calendar.badge.clock")
        }
        .disabled(miningSource != nil)

        Button {
            Task { await mineNow("birthdays") }
        } label: {
            Label("Mine Birthdays Now", systemImage: "person.crop.circle.badge.clock")
        }
        .disabled(miningSource != nil)

        if let miningStatus {
            Text(miningStatus)
        }

        Divider()

        Button(String(localized: "menubar.open", defaultValue: "Open MOOTx01")) {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Divider()

        Button(String(localized: "menubar.quit", defaultValue: "Quit MOOTx01")) {
            NSApplication.shared.terminate(nil)
        }
    }

    @MainActor
    private func mineNow(_ sourceID: String) async {
        miningSource = sourceID
        defer { miningSource = nil }
        do {
            let caller = try await GatewayRuntime.shared.bridge()
            let loop = MinerRunLoop.liveLoop()
            if let summary = await loop.runNow(sourceID: sourceID, now: Date(), caller: caller) {
                miningStatus = "Filed \(summary.result.filed) from \(sourceID)."
            } else {
                miningStatus = "\(sourceID): \(loop.lastStatus(for: sourceID) ?? "not enabled")"
            }
        } catch {
            miningStatus = error.localizedDescription
        }
    }
}
#endif
