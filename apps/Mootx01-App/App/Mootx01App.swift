import SwiftUI
import AppIntents
import GatewayUI
import MootGateway  // MinerRunLoop + GatewayRuntime (M-ING-2 executor)
#if os(macOS)
import AppKit
#elseif os(iOS)
import BackgroundTasks
#endif

// MARK: - Mootx01App
//
// The MOOTx01 ecosystem app — the Apple presentation layer of ADR-005. One
// codebase, two app targets (macOS + iOS/iPadOS), sharing the GatewayUI
// surface. Every platform runs the engine "server-in-app" (embedded); macOS
// adds the app-managed-daemon panel (Engine tab). The clean server binary is
// separate and untouched.
//
// Shortcuts registration: `Mootx01Shortcuts.updateAppShortcutParameters()` is
// called once at every app launch. The App Intents metadata extractor handles
// static phrase registration at build time (via the Xcode app bundle); this
// runtime call refreshes the donated phrases and surfaces them in the Shortcuts
// app and Siri. Without it the phrases registered at build time may go stale
// when content changes, so calling it here keeps them current.
//
// URL scheme (A5): `mootx01://x-callback-url/<verb>?…` is declared in
// project.yml → CFBundleURLTypes. The `onOpenURL` modifier on ContentView
// (below) routes inbound URLs through MootURLRouter.

@main
struct Mootx01App: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    // M-MXA-7: menu-bar headless mode is a user setting (default ON — the
    // app is the macOS mining executor per ruling D9 and must survive its
    // last window closing). The same flag drives menu-bar item insertion
    // here and the termination policy in MacAppDelegate.
    #if os(macOS)
    @AppStorage(MenuBarPolicy.defaultsKey) private var menuBarModeEnabled = true
    #endif

    init() {
        #if DEBUG
        EstateConfigurationResolver.installDebugLaunchOverride()
        #endif
        GatewayRuntime.installIntentProvider()
        #if os(iOS)
        IOSMiningBackgroundTasks.register()
        Task { await IOSMiningBackgroundTasks.schedule() }
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            #if os(macOS)
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .task { await model.start() }
                .task { Mootx01Shortcuts.updateAppShortcutParameters() }
                .task { await ShareInboxDrain.drainNow() }
            #else
            ContentView(model: model)
                .task { await model.start() }
                .task { Mootx01Shortcuts.updateAppShortcutParameters() }
                .task { await ShareInboxDrain.drainNow() }
                // A4b: content shared while the app was backgrounded drains
                // on the next foregrounding, not only at launch.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await ShareInboxDrain.drainNow() }
                }
            #endif
        }

        #if os(macOS)
        // Headless surface (M-MXA-7): estate status + reopen + quit; the
        // embedded engine stays alive while only this item remains.
        MenuBarExtra(
            String(localized: "menubar.title", defaultValue: "MOOTx01"),
            systemImage: "brain",
            isInserted: $menuBarModeEnabled
        ) {
            MenuBarView(model: model)
        }
        #endif
    }
}

#if os(iOS)
/// Opportunistic iOS refresh. Cadence remains a request to the system, not a
/// promise of exact execution time. Disabled and unauthorized miners are
/// skipped without prompting.
private enum IOSMiningBackgroundTasks {
    static let identifier = "com.codedaptive.mootx01.mining.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let handle = BackgroundRefreshHandle(refresh)
            let work = Task {
                do {
                    let caller = try await GatewayRuntime.shared.bridge()
                    _ = await MinerRunLoop.liveLoop().tick(now: Date(), caller: caller)
                    // A4b: the refresh window also drains any spooled shares.
                    await ShareInboxDrain.drainNow()
                    handle.task.setTaskCompleted(success: !Task.isCancelled)
                } catch {
                    handle.task.setTaskCompleted(success: false)
                }
                await schedule()
            }
            refresh.expirationHandler = {
                work.cancel()
            }
        }
    }

    static func schedule() async {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? await BGTaskScheduler.shared.submitTaskRequest(request)
    }
}

private final class BackgroundRefreshHandle: @unchecked Sendable {
    let task: BGAppRefreshTask
    init(_ task: BGAppRefreshTask) { self.task = task }
}
#endif

#if os(macOS)
/// A bundled macOS app activates normally; this only forces foreground focus
/// when launched from a tool/`open` so the window comes forward.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// M-ING-2 executor: process-lifetime scheduler tick (hourly), alive in
    /// headless menu-bar mode where scene tasks are not. Every tick is a
    /// no-op until the user enables a source in the Miners tab, and cadence
    /// gating (MinerScheduler) decides when an enabled source actually runs.
    private var minerTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        minerTask = Task {
            let loop = MinerRunLoop.liveLoop()
            while !Task.isCancelled {
                if let bridge = try? await GatewayRuntime.shared.bridge() {
                    _ = await loop.tick(now: Date(), caller: bridge)
                }
                // A4b: headless menu-bar mode still drains spooled shares.
                await ShareInboxDrain.drainNow()
                try? await Task.sleep(for: .seconds(3_600))
            }
        }
    }
    /// M-MXA-7 termination policy: with menu-bar mode ON the app survives
    /// its last window closing (headless mining executor, ruling D9); with
    /// it OFF the pre-M-MXA-7 quit-on-close behavior is preserved.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MenuBarPolicy.shouldTerminateAfterLastWindowClosed(
            menuBarModeEnabled: MenuBarPolicy.isEnabled()
        )
    }
}
#endif
